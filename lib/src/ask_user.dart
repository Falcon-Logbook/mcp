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

  /// Remembers [questions] and returns the token that resumes them.
  String remember(List<Question> questions) {
    _forgetExpired();
    final token = _newToken();
    _pending[token] = _PendingAsk(
      signature: _signatureOf(questions),
      expires: _clock().add(ttl),
    );
    return token;
  }

  /// Consumes [token] for [questions].
  ///
  /// Returns why it cannot be used, or null when it was used. A token is spent
  /// on use, so a second attempt with the same one is refused: the answers
  /// belong to the first call that sent them.
  String? consume(String token, List<Question> questions) {
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
/// on; wording and option order may change between a call and its retry.
String _signatureOf(List<Question> questions) => [
      for (final question in questions) '${question.id}:${question.type.name}'
    ].join(' ');

/// Runs one `ask_user` call over whichever of the three paths this connection
/// allows.
///
/// - stateless with form elicitation: returns [InputRequiredResult], and the
///   retry arrives in [inputResponses] with the [requestState] token.
/// - legacy session with form elicitation: asks with [elicit] inside this call.
/// - anything else: returns [needsInput] and completes from `answers`.
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
  final unknown = _unknownIn(args, _argumentFields);
  if (unknown.isNotEmpty) {
    _refuse(
        unknown.first,
        'Unknown field(s): ${unknown.join(', ')}. '
        'Supported: ${_sorted(_argumentFields)}',
        code: 'unknown_field');
  }
  final answers = switch (args['answers']) {
    null => null,
    final Map<dynamic, dynamic> answers => answers,
    _ => _refuse('answers', 'answers must be an object keyed by question id'),
  };
  final action = _parseAction(args['action']);
  final questions = parseQuestions(args['questions']);

  if (inputResponses != null) {
    if (requestState == null) {
      _refuse('requestState',
          'inputResponses requires the requestState from the first call');
    }
    final refused = state.consume(requestState, questions);
    if (refused != null) return needsInput(questions, reason: refused);
    final response = inputResponses[askUserInputKey];
    if (response == null) {
      _refuse(
          'inputResponses',
          'inputResponses["$askUserInputKey"] is missing. '
              'Answer the question that was asked.');
    }
    return readElicitResponse(response.value, questions);
  }
  if (requestState != null) {
    _refuse('inputResponses',
        'requestState was sent without inputResponses. Send both, or neither.');
  }

  if (answers != null || args.containsKey('action')) {
    if (action == ElicitAction.decline) return _status('declined');
    if (action == ElicitAction.cancel) return _status('cancelled');
    return _answered(
        readAnswers(answers ?? const <String, Object?>{}, questions));
  }

  if (!canElicit) return needsInput(questions);
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
/// The fallback keeps no server state. It asks the caller to send the same
/// questions back with `answers`, so the ids stay the contract and every
/// answer is checked against the same schema the form would have used.
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

/// Checks [content] against [questions] and returns the answers by id.
///
/// The protocol validates the shape of a response but not its content, so this
/// is the only check between a client and a flow: unknown ids and values that
/// are not one of the offered options are refused by name, and an optional
/// question the client left out takes its default.
Map<String, Object?> readAnswers(
  Map<dynamic, dynamic> content,
  List<Question> questions,
) {
  final known = {for (final question in questions) question.id};
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
  for (final question in questions) {
    final value = content[question.id];
    if (value == null) {
      if (question.required) {
        _refuse('answers.${question.id}',
            '${question.id} is required: ${question.question}');
      }
      if (question.defaultValue != null) {
        answers[question.id] = question.defaultValue;
      }
      continue;
    }
    answers[question.id] = _checkAnswer(question, value);
  }
  return answers;
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

const _argumentFields = {'questions', 'answers', 'action'};

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
      if (!question.options.any((option) => option.value == value)) {
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
      if (unknown.isNotEmpty) {
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

/// The answers of a completed form, keyed by question id.
CallToolResult _answered(Map<String, Object?> answers) =>
    _result({'status': 'answered', 'answers': answers});

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
