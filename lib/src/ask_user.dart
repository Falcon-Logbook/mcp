import 'dart:convert';
import 'dart:math';

import 'package:mcp_dart/mcp_dart.dart';

import 'questions.dart';

/// The key of the single input request in a form, and therefore of the client
/// response that carries its answers.
const askUserInputKey = 'questions';

/// The longest a question set waits for an answer. Long enough for a pilot to
/// read the form, short enough that a forgotten tab cannot be resumed days
/// later against a logbook that has moved on.
const askStateTtl = Duration(minutes: 5);

/// The arguments `ask_user` accepts.
///
/// Deliberately thin: the shape of a question is described in the tool text and
/// enforced here rather than spelled out as JSON Schema. Tools are listed in
/// every session, so a nested schema per question field would cost each
/// session more than the one error message it would save.
final JsonObject askUserInputSchema = JsonSchema.object(properties: {
  'questions': JsonSchema.array(
    description: 'One object per question: id, question, type, and options of '
        'value and label for choice and multi.',
  ),
  'answers': JsonSchema.fromJson(const {}),
  'action': JsonSchema.string(
      enumValues: const ['accept', 'decline', 'cancel'],
      description: 'How the user answered. Defaults to accept.'),
});

/// The arguments `ask_user` accepts.
///
/// The registration refuses any other name with the same `unknown_field`
/// envelope every other tool uses, which is why the names are published rather
/// than kept private here.
const askUserArgumentFields = {'questions', 'answers', 'action'};

/// A question the server refuses to ask, or an answer it refuses to accept.
///
/// It carries the same three parts as every other tool error: a stable [code],
/// the [field] at fault, and one sentence of detail. The registration turns it
/// into the `{error, field, detail}` envelope a caller already parses, so a
/// refusal from `ask_user` reads like a refusal from any other tool.
class AskUserError implements Exception {
  AskUserError(this.message, {this.code = 'invalid_value', this.field});

  final String message;

  /// One of the codes the server reports: `unknown_field` for a name it does
  /// not write, `invalid_value` for everything it writes but cannot use.
  final String code;

  /// The argument at fault, spelled the way the caller sent it:
  /// `questions[0].type` for a question field, `answers.aircraft` for an
  /// answer, `action` for the action.
  final String? field;

  @override
  String toString() => message;
}

/// Refuses [detail] at [field], the one shape every validation here raises.
Never _refuse(String field, String detail, {String code = 'invalid_value'}) =>
    throw AskUserError(detail, code: code, field: field);

/// Answers a caller sent to a stateless call that is waiting for input.
///
/// A state is a random token, not a payload: the questions it belongs to live
/// in [_pending] for the life of the process. That gives integrity (the token
/// cannot be guessed or built by a client), expiry and single use without
/// signing anything, and it keeps a restart safe, because every token dies
/// with the process that issued it.
class AskStateStore {
  AskStateStore({DateTime Function()? clock, this.ttl = askStateTtl})
      : _clock = clock ?? DateTime.now;

  final Duration ttl;
  final DateTime Function() _clock;
  final Map<String, _PendingAsk> _pending = {};
  final Random _random = Random.secure();

  List<Question>? _flow;

  /// The questions of the flow the client was last handed, if any.
  ///
  /// A token is not always echoed back: a client with no form answers with the
  /// answers alone, which leaves the server with no other record of what it
  /// asked. The required questions of [flow] are what such a call is judged
  /// against, so one flow is kept for the life of the process and replaced by
  /// the next ask.
  List<Question>? get flow => _flow;

  /// Records [questions] as the flow a later call may answer without resending
  /// them.
  void recordFlow(List<Question> questions) => _flow = questions;

  /// Remembers [questions] and returns the token that resumes them.
  String remember(List<Question> questions) {
    _forgetExpired();
    recordFlow(questions);
    final token = _newToken();
    _pending[token] = _PendingAsk(
      signature: _signatureOf(questions),
      expires: _clock().add(ttl),
    );
    return token;
  }

  /// Why [token] cannot be used for [questions], or null when it can.
  ///
  /// Nothing that is still usable is spent here: a caller that goes on to
  /// refuse the answers leaves the form answerable with the same token.
  String? check(String token, List<Question> questions) {
    final pending = _pending[token];
    if (pending == null) {
      return 'These answers no longer match a waiting question. Ask again.';
    }
    if (!_clock().isBefore(pending.expires)) {
      _pending.remove(token);
      return 'The questions expired before they were answered. Ask again.';
    }
    if (pending.signature != _signatureOf(questions)) {
      _pending.remove(token);
      return 'The questions changed while they were waiting for an answer. '
          'Ask again.';
    }
    return null;
  }

  /// Consumes [token] for [questions].
  ///
  /// Returns why it cannot be used, or null when it was used. A token is spent
  /// on use, so a second attempt with the same one is refused: the answers
  /// belong to the first call that sent them.
  String? consume(String token, List<Question> questions) {
    final refused = check(token, questions);
    if (refused != null) return refused;
    _pending.remove(token);
    return null;
  }

  /// How many question sets are waiting for an answer.
  int get pending => _pending.length;

  void _forgetExpired() {
    final now = _clock();
    _pending.removeWhere((_, pending) => !now.isBefore(pending.expires));
  }

  String _newToken() {
    final bytes = List<int>.generate(32, (_) => _random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }
}

class _PendingAsk {
  const _PendingAsk({required this.signature, required this.expires});

  /// Which questions this token was issued for: their ids and kinds.
  final String signature;

  final DateTime expires;
}

/// What a token was issued for. Ids and types are the part an answer depends
/// on; wording and option order may change between a call and its retry, and a
/// client that stores the questions in a set may echo them in another order.
/// Sorted so only the set of ids and types is compared. Ids are unique and
/// neither they nor type names contain a space, so the joined form cannot
/// collide across different sets.
String _signatureOf(List<Question> questions) => ([
      for (final question in questions) '${question.id}:${question.type.name}'
    ]..sort())
        .join(' ');

/// Runs one `ask_user` call over whichever of the three paths this connection
/// allows.
///
/// - stateless with form elicitation: returns [InputRequiredResult], and the
///   retry arrives in [inputResponses] with the [requestState] token.
/// - legacy session with form elicitation: asks with [elicit] inside this call.
/// - anything else: returns [needsInput] and completes from `answers`.
///
/// `questions` is required to start an exchange and to answer one through
/// [inputResponses]. A completion call may leave them out and send `answers`
/// alone: the ids are then checked against the catalogue, and the required
/// questions of the flow the server last asked ([AskStateStore.flow]) must be
/// answered, because a client that simply omits one never sends it.
///
/// [canElicit] is decided by the caller from the capabilities the client
/// declared, because the server raises the missing-capability error after the
/// callback has returned: there is nothing in here to catch.
Future<BaseResultData> askUser(
  Map<String, dynamic> args, {
  required bool stateless,
  required bool canElicit,
  required Future<ElicitResult> Function(ElicitRequest request) elicit,
  required AskStateStore state,
  InputResponses? inputResponses,
  String? requestState,
}) async {
  final answers = switch (args['answers']) {
    null => null,
    final Map<dynamic, dynamic> answers => answers,
    _ => _refuse('answers', 'answers must be an object keyed by question id'),
  };
  final action = _parseAction(args['action']);

  if (inputResponses != null) {
    final questions = parseQuestions(args['questions']);
    if (requestState == null) {
      _refuse('requestState',
          'inputResponses requires the requestState from the first call');
    }
    final refused = state.check(requestState, questions);
    if (refused != null) return needsInput(questions, reason: refused);
    final response = inputResponses[askUserInputKey];
    if (response == null) {
      _refuse(
          'inputResponses',
          'inputResponses["$askUserInputKey"] is missing. '
              'Answer the question that was asked.');
    }
    // The answers are read before the token is spent, so a refusal here leaves
    // the form answerable: a retry with a corrected answer still finds it.
    final answered = readElicitResponse(response.value, questions);
    final spent = state.consume(requestState, questions);
    if (spent != null) return needsInput(questions, reason: spent);
    return answered;
  }
  if (requestState != null) {
    _refuse('inputResponses',
        'requestState was sent without inputResponses. Send both, or neither.');
  }

  if (answers != null || args.containsKey('action')) {
    if (action == ElicitAction.decline) return _status('declined');
    if (action == ElicitAction.cancel) return _status('cancelled');
    // Questions are optional here. An agent that echoes them is checked
    // against exactly those, defaults included; one that sends answers alone is
    // checked against the flow the server last asked, because a required
    // question the client leaves out never appears in the answers.
    final questions = args.containsKey('questions')
        ? parseQuestions(args['questions'])
        : null;
    if (answers == null && questions == null) {
      _refuse('answers',
          'accepting needs answers: one value per question id, or decline');
    }
    final content = answers ?? const <Object?, Object?>{};
    if (questions == null) _requireFlowAnswers(content, state);
    return _answered(readAnswers(content, questions));
  }

  final questions = parseQuestions(args['questions']);
  if (!canElicit) {
    state.recordFlow(questions);
    return needsInput(questions);
  }
  final request = elicitRequest(questions);
  if (stateless) {
    return InputRequiredResult(
      inputRequests: {askUserInputKey: InputRequest.elicit(request)},
      requestState: state.remember(questions),
    );
  }
  return _fromElicitResult(await elicit(request), questions);
}

/// The form request for [questions]: one flat schema, one line of message.
///
/// The schema is built from primitive properties only, and a choice without
/// options is refused here rather than sent as a form with an empty list, so
/// this cannot produce a shape the protocol refuses.
ElicitRequest elicitRequest(List<Question> questions) {
  for (final (index, question) in questions.indexed) {
    final needsOptions = question.type == QuestionType.choice ||
        question.type == QuestionType.multi;
    if (needsOptions && question.options.isEmpty) {
      _refuse(
          'questions[$index].options',
          '${question.id} is a ${question.type.name} question '
              'with no options to choose from');
    }
  }
  return ElicitRequest.form(
    message: 'Falcon needs your answers to carry on.',
    requestedSchema: JsonSchema.object(
      properties: {
        for (final question in questions)
          question.id: question.toElicitationSchema(),
      },
      required: [
        for (final question in questions)
          if (question.required) question.id,
      ],
    ),
  );
}

/// The result for a client that cannot show a form: the same questions, as
/// data, with [reason] set when a question set could not be resumed.
///
/// The fallback keeps no server state. It asks the caller to answer by question
/// id, and that call may leave the questions out: the ids are then checked
/// against the catalogue, which is the list this result just handed over.
CallToolResult needsInput(List<Question> questions, {String? reason}) =>
    _result({
      'status': 'needs_input',
      'questions': [for (final question in questions) question.toJson()],
      if (reason != null) 'reason': reason,
    });

/// Reads a form the user answered in the client.
///
/// Decline and cancel are answers, not errors: the flow stops and says what it
/// did not do.
CallToolResult readElicitResponse(
  Map<String, dynamic> response,
  List<Question> questions,
) {
  final ElicitResult result;
  try {
    result = ElicitResult.fromJson(response);
  } on FormatException catch (error) {
    _refuse(
        'inputResponses',
        'inputResponses["$askUserInputKey"] is not a form '
            'answer: ${error.message}');
  }
  return _fromElicitResult(result, questions);
}

/// The answers of a completed form, and which of them the server supplied.
///
/// A caller that cannot tell its own answer from a default could report a
/// guess as a fact, so [defaulted] names every id that was filled in rather
/// than answered.
typedef AnswerSet = ({Map<String, Object?> answers, List<String> defaulted});

/// Checks [content] against [questions] and returns the answers by id.
///
/// The protocol validates the shape of a response but not its content, so this
/// is the only check between a client and a flow: unknown ids and values that
/// are not one of the offered options are refused by name, and an optional
/// question the client left out takes its default, reported in
/// [AnswerSet.defaulted].
///
/// [questions] may be null, which is a call that answers without resending them.
/// The ids are then checked against [AskQuestions.byId] and each value against
/// the type the catalogue gives it. A default is never filled on that path: the
/// server cannot tell which of the optional questions were asked. Which
/// required questions must be present is decided by [askUser] from the flow it
/// last asked, because the catalogue alone would demand every required question
/// in it, including the ones no flow asked.
AnswerSet readAnswers(
  Map<dynamic, dynamic> content,
  List<Question>? questions,
) {
  final known = questions == null
      ? AskQuestions.ids.toSet()
      : {for (final question in questions) question.id};
  final unknown = [
    for (final key in content.keys)
      if (!known.contains('$key')) '$key',
  ]..sort();
  if (unknown.isNotEmpty) {
    final expected = known.toList()..sort();
    _refuse(
        'answers',
        'Unknown answer(s): ${unknown.join(', ')}. Expected: '
            '${expected.join(', ')}');
  }

  final answers = <String, Object?>{};
  final defaulted = <String>[];
  for (final question in questions ?? _catalogueQuestions(content)) {
    final value = content[question.id];
    if (value == null) {
      if (question.required) {
        _refuse('answers.${question.id}',
            '${question.id} is required: ${question.question}');
      }
      if (question.defaultValue != null) {
        answers[question.id] = question.defaultValue;
        defaulted.add(question.id);
      }
      continue;
    }
    answers[question.id] = _checkAnswer(question, value);
  }
  return (answers: answers, defaulted: defaulted);
}

/// Refuses [content] when it leaves out a required question of [state]'s flow.
///
/// Only the required entries of the flow the server last asked are enforced:
/// an optional question may be left out, and a required question of a flow that
/// was never asked is not required here. The refusal is the one [readAnswers]
/// raises when the questions are resent, so the two paths agree.
void _requireFlowAnswers(Map<Object?, Object?> content, AskStateStore state) {
  for (final question in state.flow ?? const <Question>[]) {
    if (!question.required || content[question.id] != null) continue;
    _refuse('answers.${question.id}',
        '${question.id} is required: ${question.question}');
  }
}

/// The catalogue questions [content] answers, in the order they were sent.
///
/// Every key has a question by the time this runs: the ids were checked above.
Iterable<Question> _catalogueQuestions(Map<dynamic, dynamic> content) sync* {
  for (final key in content.keys) {
    final question = AskQuestions.byId('$key');
    if (question != null) yield question;
  }
}

/// Parses the `questions` argument into the questions the server will ask.
List<Question> parseQuestions(Object? value) {
  if (value is! List || value.isEmpty) {
    _refuse('questions', 'questions must be a non-empty array');
  }
  final questions = <Question>[];
  final seen = <String>{};
  for (final (index, raw) in value.indexed) {
    if (raw is! Map) {
      _refuse('questions[$index]', 'questions[$index] must be an object');
    }
    final question = _parseQuestion(Map<String, dynamic>.from(raw), index);
    if (!seen.add(question.id)) {
      _refuse('questions[$index].id', 'Duplicate question id: ${question.id}');
    }
    questions.add(question);
  }
  return questions;
}

const _questionFields = {
  'id',
  'header',
  'question',
  'type',
  'options',
  'default',
  'required',
};

const _optionFields = {'value', 'label', 'description'};

Question _parseQuestion(Map<String, dynamic> json, int index) {
  final where = 'questions[$index]';
  final unknown = _unknownIn(json, _questionFields);
  if (unknown.isNotEmpty) {
    _refuse(
        where,
        '$where has unknown field(s): ${unknown.join(', ')}. '
        'Supported: ${_sorted(_questionFields)}',
        code: 'unknown_field');
  }

  final id = json['id'];
  if (id is! String || !_idPattern.hasMatch(id)) {
    _refuse(
        '$where.id',
        '$where.id must be a name such as "aircraft": up to '
            '40 lowercase letters, digits or underscores, starting with a letter');
  }
  final text = json['question'];
  if (text is! String || text.trim().isEmpty) {
    _refuse('$where.question', '$where.question must be one sentence of text');
  }
  final header = json['header'];
  if (header != null && (header is! String || header.trim().isEmpty)) {
    _refuse('$where.header', '$where.header must be a short label');
  }
  final type = _byName(QuestionType.values, json['type']);
  if (type == null) {
    _refuse(
        '$where.type',
        '$where.type must be one of '
            '${QuestionType.values.map((type) => type.name).join(', ')}');
  }
  final required = json['required'];
  if (required != null && required is! bool) {
    _refuse('$where.required', '$where.required must be true or false');
  }

  final options = _parseOptions(json['options'], where, type);
  return Question(
    id: id,
    header: header as String?,
    question: text,
    type: type,
    options: options,
    defaultValue: _parseDefault(json['default'], where, type, options),
    required: required == true,
  );
}

List<QuestionOption> _parseOptions(
  Object? value,
  String where,
  QuestionType type,
) {
  final needsOptions =
      type == QuestionType.choice || type == QuestionType.multi;
  if (value == null) {
    if (needsOptions) {
      _refuse('$where.options',
          '$where.options is required for a ${type.name} question');
    }
    return const [];
  }
  if (!needsOptions) {
    _refuse(
        '$where.options',
        '$where.options is not allowed for a '
            '${type.name} question');
  }
  if (value is! List || value.isEmpty) {
    _refuse('$where.options', '$where.options must be a non-empty array');
  }
  final options = <QuestionOption>[];
  final seen = <String>{};
  for (final (index, raw) in value.indexed) {
    if (raw is! Map) {
      _refuse(
          '$where.options[$index]', '$where.options[$index] must be an object');
    }
    final option = Map<String, dynamic>.from(raw);
    final unknown = _unknownIn(option, _optionFields);
    if (unknown.isNotEmpty) {
      _refuse(
          '$where.options[$index]',
          '$where.options[$index] has unknown field(s): '
              '${unknown.join(', ')}. Supported: ${_sorted(_optionFields)}',
          code: 'unknown_field');
    }
    final optionValue = option['value'];
    if (optionValue is! String) {
      _refuse('$where.options[$index].value',
          '$where.options[$index].value must be a string');
    }
    if (!seen.add(optionValue)) {
      _refuse('$where.options[$index].value',
          '$where.options repeats the value "$optionValue"');
    }
    final label = option['label'];
    if (label != null && (label is! String || label.trim().isEmpty)) {
      _refuse('$where.options[$index].label',
          '$where.options[$index].label must be a string');
    }
    final description = option['description'];
    if (description != null && description is! String) {
      _refuse('$where.options[$index].description',
          '$where.options[$index].description must be a string');
    }
    options.add(QuestionOption(optionValue, label as String? ?? optionValue,
        description: description as String?));
  }
  return options;
}

Object? _parseDefault(
  Object? value,
  String where,
  QuestionType type,
  List<QuestionOption> options,
) {
  if (value == null) return null;
  final allowed = [for (final option in options) option.value].join(', ');
  switch (type) {
    case QuestionType.choice:
      if (value is! String || !options.any((o) => o.value == value)) {
        _refuse('$where.default',
            '$where.default must be one of the option values: $allowed');
      }
      return value;
    case QuestionType.multi:
      if (value is! List ||
          value.any((item) =>
              item is! String || !options.any((o) => o.value == item))) {
        _refuse('$where.default',
            '$where.default must be a list of the option values: $allowed');
      }
      return List<String>.from(value);
    case QuestionType.boolean:
      if (value is! bool) {
        _refuse('$where.default', '$where.default must be true or false');
      }
      return value;
    case QuestionType.text:
      if (value is! String) {
        _refuse('$where.default', '$where.default must be a string');
      }
      return value;
  }
}

Object? _checkAnswer(Question question, Object? value) {
  final id = question.id;
  final field = 'answers.$id';
  switch (question.type) {
    case QuestionType.choice:
      if (value is! String) {
        _refuse(field, '$id must be one of the option values, as a string');
      }
      // A question rebuilt from the catalogue for a call that did not resend it
      // carries no options, so only its type can be checked: the flow that
      // asked is the only place that knows the values it offered.
      if (question.options.isNotEmpty &&
          !question.options.any((option) => option.value == value)) {
        _refuse(
            field,
            '$id must be one of: ${question.options.map((o) => o.value).join(', ')}'
            ' (got "$value")');
      }
      return value;
    case QuestionType.multi:
      if (value is! List || value.any((item) => item is! String)) {
        _refuse(field, '$id must be a list of option values');
      }
      final known = {for (final option in question.options) option.value};
      final unknown = [
        for (final item in value.cast<String>())
          if (!known.contains(item)) item,
      ];
      if (known.isNotEmpty && unknown.isNotEmpty) {
        _refuse(
            field,
            '$id must be made of: ${known.join(', ')} '
            '(got ${unknown.join(', ')})');
      }
      if (value.toSet().length != value.length) {
        _refuse(field, '$id must not repeat an option');
      }
      return List<String>.from(value);
    case QuestionType.boolean:
      if (value is! bool) _refuse(field, '$id must be true or false');
      return value;
    case QuestionType.text:
      if (value is! String) _refuse(field, '$id must be text');
      return value;
  }
}

/// The answers of a completed form, keyed by question id, with the ids the
/// server filled in itself.
CallToolResult _answered(AnswerSet read) => _result({
      'status': 'answered',
      'answers': read.answers,
      'defaulted': read.defaulted,
    });

/// A form the user declined or cancelled. Not an error: the flow stops here.
CallToolResult _status(String status) => _result({'status': status});

CallToolResult _result(Map<String, Object?> payload) => CallToolResult(
      content: [TextContent(text: jsonEncode(payload))],
      structuredContent: payload,
    );

CallToolResult _fromElicitResult(
    ElicitResult result, List<Question> questions) {
  if (result.action == ElicitAction.decline.name) {
    return _status('declined');
  }
  if (result.action == ElicitAction.cancel.name) {
    return _status('cancelled');
  }
  return _answered(
      readAnswers(result.content ?? const <String, Object?>{}, questions));
}

ElicitAction _parseAction(Object? value) {
  if (value == null) return ElicitAction.accept;
  final parsed = _byName(ElicitAction.values, value);
  if (parsed == null) {
    _refuse(
        'action',
        'action must be one of accept, decline, cancel '
            '(got "$value")');
  }
  return parsed;
}

/// The enum case named [name], or null when there is none.
T? _byName<T extends Enum>(List<T> values, Object? name) {
  for (final value in values) {
    if (value.name == name) return value;
  }
  return null;
}

List<String> _unknownIn(Map<String, dynamic> json, Set<String> allowed) => [
      for (final key in json.keys)
        if (!allowed.contains(key)) key,
    ]..sort();

String _sorted(Set<String> values) => (values.toList()..sort()).join(', ');

/// The three answers a form can come back with. Mirrors the protocol's
/// elicitation action so the fallback and the form speak the same words.
enum ElicitAction { accept, decline, cancel }

final _idPattern = RegExp(r'^[a-z][a-z0-9_]{0,39}$');
