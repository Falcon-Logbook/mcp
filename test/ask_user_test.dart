import 'package:falcon_mcp/falcon_mcp.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:test/test.dart';

/// The roster questions, built the way #3 builds them.
List<Question> roster() => [
      AskQuestions.aircraft(const [
        QuestionOption('ac-1', 'VH-XZO', description: 'B738'),
      ]),
      AskQuestions.timeBasis,
      AskQuestions.crewRole,
      AskQuestions.selectLegs(const [
        QuestionOption('fl-1', 'YSSY - NZQN'),
        QuestionOption('fl-2', 'YSBK - YSSY'),
      ]),
      AskQuestions.createMissingCrew,
    ];

/// Every catalogue entry, in the order of [AskQuestions.ids].
List<Question> catalogue() => [
      ...roster(),
      AskQuestions.columnDate(const ['Date', 'Route', 'Total']),
      AskQuestions.durationFormat,
      AskQuestions.unmappedColumn('Pilot notes'),
      AskQuestions.confirmPlan,
      AskQuestions.deleteRows(3),
    ];

/// A catalogue question as it goes on the wire, after the SDK has built and
/// validated the request around it.
Map<String, dynamic> wireProperty(String id, [List<Question>? questions]) {
  final form = elicitRequest(questions ?? catalogue())
      .toJson(protocolVersion: '2026-07-28');
  final requested = form['requestedSchema'] as Map<String, dynamic>;
  final properties = requested['properties'] as Map<String, dynamic>;
  return properties[id] as Map<String, dynamic>;
}

Future<BaseResultData> ask(
  Map<String, dynamic> args, {
  bool stateless = false,
  bool canElicit = false,
  AskStateStore? state,
  InputResponses? inputResponses,
  String? requestState,
}) =>
    askUser(
      args,
      stateless: stateless,
      canElicit: canElicit,
      elicit: (request) async => const ElicitResult(action: 'cancel'),
      state: state ?? AskStateStore(),
      inputResponses: inputResponses,
      requestState: requestState,
    );

Map<String, dynamic> payloadOf(BaseResultData result) {
  expect(result, isA<CallToolResult>());
  return (result as CallToolResult).structuredContent!;
}

void main() {
  group('question schema', () {
    test('every catalogue question builds a flat form the protocol accepts',
        () {
      // toJson validates the flatness rules: primitive properties, no nested
      // objects, no arrays of objects. A nested property throws here.
      final form =
          elicitRequest(catalogue()).toJson(protocolVersion: '2026-07-28');
      final requested = form['requestedSchema'] as Map<String, dynamic>;
      expect(requested.keys,
          everyElement(isIn(['type', 'properties', 'required'])));
      expect(requested['type'], 'object');

      const allowedPropertyKeys = {
        'type',
        'title',
        'description',
        'default',
        'enum',
        'oneOf',
        'anyOf',
        'items',
        'minItems',
        'maxItems',
      };
      final properties = requested['properties'] as Map<String, dynamic>;
      expect(properties.keys, AskQuestions.ids);
      for (final entry in properties.entries) {
        final property = entry.value as Map<String, dynamic>;
        expect(property.keys, everyElement(isIn(allowedPropertyKeys)),
            reason: '${entry.key} emits an unsupported keyword');
        expect(property['type'], isNot('object'),
            reason: '${entry.key} must not be a nested object');
        final items = property['items'];
        if (items is Map) {
          expect(items['type'], isNot('object'),
              reason: '${entry.key} must not be an array of objects');
          expect(items.keys, everyElement(isIn(['type', 'enum', 'anyOf'])));
        }
      }
    });

    test('the required list is the questions a flow must have answered', () {
      final form =
          elicitRequest(catalogue()).toJson(protocolVersion: '2026-07-28');
      final requested = form['requestedSchema'] as Map<String, dynamic>;
      expect(requested['required'], [
        AskQuestions.columnDateId,
        AskQuestions.durationFormatId,
        AskQuestions.confirmPlanId,
        AskQuestions.deleteRowsId,
      ]);
    });

    test('choice, multi and boolean render as the protocol primitives', () {
      final choice = wireProperty(AskQuestions.timeBasisId);
      expect(choice['type'], 'string');
      expect(choice['title'], 'Time');
      expect(choice['default'], 'utc');
      expect(
        (choice['oneOf'] as List).map((option) => (option as Map)['const']),
        ['utc', 'local', 'airport_local'],
      );
      expect((choice['oneOf'] as List).first, {
        'const': 'utc',
        'title': 'UTC (Coordinated Universal Time)',
      });

      final multi = wireProperty(AskQuestions.selectLegsId);
      expect(multi['type'], 'array');
      expect(multi['default'], ['fl-1', 'fl-2']);
      expect(multi['items'], {
        'type': 'string',
        'anyOf': [
          {'const': 'fl-1', 'title': 'YSSY - NZQN'},
          {'const': 'fl-2', 'title': 'YSBK - YSSY'},
        ],
      });

      expect(wireProperty(AskQuestions.createMissingCrewId), {
        'title': 'Crew',
        'description': 'Create crew members that do not exist?',
        'default': false,
        'type': 'boolean',
      });
    });

    test('a choice keeps the catalogue explanation the oneOf would drop', () {
      // oneOf allows a const and a title only, so the explanation has to sit in
      // the label to reach a form at all. multi keeps it inside anyOf, which is
      // why this is folded rather than added to the question text as well.
      for (final (id, value, explanation) in [
        (AskQuestions.timeBasisId, 'utc', 'Coordinated Universal Time'),
        (AskQuestions.crewRoleId, 'pilotInCommand', 'Pilot in Command'),
        (
          AskQuestions.unmappedColumnId,
          'custom_columns',
          'Stored with the flight, shown in its own column',
        ),
      ]) {
        final property = wireProperty(id);
        final title = ((property['oneOf'] as List)
            .map((entry) => entry as Map)
            .firstWhere((entry) => entry['const'] == value))['title'] as String;
        expect(title, contains(explanation));
        expect(property['description'], isNot(contains(explanation)),
            reason: 'the question text must not repeat the label');
      }
    });

    test('a text question is a plain string the protocol accepts', () {
      final text = parseQuestions(const [
        {
          'id': 'note',
          'header': 'Note',
          'question': 'Anything?',
          'type': 'text'
        },
      ]).single;
      expect(wireProperty('note', [text]), {
        'title': 'Note',
        'description': 'Anything?',
        'type': 'string',
      });
    });

    test('a multi-select default survives into the schema', () {
      final multi = wireProperty(AskQuestions.selectLegsId);
      expect(multi['default'], ['fl-1', 'fl-2']);
      final empty = elicitRequest([
        AskQuestions.selectLegs(const [QuestionOption('fl-1', 'A')])
      ]).toJson(protocolVersion: '2026-07-28');
      final properties = ((empty['requestedSchema'] as Map)['properties']
          as Map<String, dynamic>);
      expect(
          (properties[AskQuestions.selectLegsId] as Map)['default'], ['fl-1']);
    });

    test('the catalogue ids are stable, unique and schema-safe', () {
      expect(AskQuestions.ids.toSet(), hasLength(AskQuestions.ids.length));
      for (final id in AskQuestions.ids) {
        expect(id, matches(RegExp(r'^[a-z][a-z0-9_]*$')));
        // Every id a caller can answer resolves to a question, which is what
        // an answer without the questions is checked against.
        expect(AskQuestions.byId(id)?.id, id);
      }
      expect(AskQuestions.byId('airecraft'), isNull);
      // Each factory uses the id it exports, so a flow reads the answer by the
      // constant rather than by a copied string.
      expect(AskQuestions.aircraft(const [QuestionOption('a', 'A')]).id,
          AskQuestions.aircraftId);
      expect(AskQuestions.timeBasis.id, AskQuestions.timeBasisId);
      expect(AskQuestions.crewRole.id, AskQuestions.crewRoleId);
      expect(AskQuestions.selectLegs(const [QuestionOption('a', 'A')]).id,
          AskQuestions.selectLegsId);
      expect(
          AskQuestions.createMissingCrew.id, AskQuestions.createMissingCrewId);
      expect(
          AskQuestions.columnDate(const ['A']).id, AskQuestions.columnDateId);
      expect(AskQuestions.durationFormat.id, AskQuestions.durationFormatId);
      expect(
          AskQuestions.unmappedColumn('X').id, AskQuestions.unmappedColumnId);
      expect(AskQuestions.confirmPlan.id, AskQuestions.confirmPlanId);
      expect(AskQuestions.deleteRows(2).id, AskQuestions.deleteRowsId);
    });

    test('the delete question counts rows and says it cannot be undone', () {
      expect(AskQuestions.deleteRows(1).question,
          'Delete 1 row? This cannot be undone');
      expect(AskQuestions.deleteRows(4).question,
          'Delete 4 rows? This cannot be undone');
    });

    test('an empty aircraft list still offers leave blank', () {
      final question = AskQuestions.aircraft(const []);
      expect(question.options.map((option) => option.value),
          [AskQuestions.leaveBlank]);
      expect(question.defaultValue, AskQuestions.leaveBlank);
      // The form still builds, which is the point: a logbook with no aircraft
      // can be answered, not crashed on.
      expect(elicitRequest([question]).toJson(protocolVersion: '2026-07-28'),
          contains('requestedSchema'));
    });

    test('a choice with nothing to choose is refused by name', () {
      expect(
        () => elicitRequest([
          const Question(
            id: 'legs',
            question: 'Which legs?',
            type: QuestionType.choice,
          ),
        ]),
        throwsA(isA<AskUserError>().having((e) => e.message, 'message',
            contains('legs is a choice question'))),
      );
    });

    test('no question text carries a path, a url or a secret', () {
      final text = [
        for (final question in catalogue()) ...[
          question.question,
          if (question.header != null) question.header!,
          for (final option in question.options) ...[
            option.label,
            if (option.description != null) option.description!,
          ],
        ],
      ].join(' ');
      expect(text, isNot(contains('sqlite')));
      expect(text, isNot(contains('/')));
      expect(text, isNot(contains('http')));
      expect(text, isNot(contains('password')));
    });
  });

  group('answers', () {
    test('a missing optional answer takes its default', () {
      final read = readAnswers(const {}, roster());
      expect(read.answers, {
        AskQuestions.aircraftId: AskQuestions.leaveBlank,
        AskQuestions.timeBasisId: 'utc',
        AskQuestions.crewRoleId: 'pilotInCommand',
        AskQuestions.selectLegsId: ['fl-1', 'fl-2'],
        AskQuestions.createMissingCrewId: false,
      });
      expect(read.defaulted, [
        AskQuestions.aircraftId,
        AskQuestions.timeBasisId,
        AskQuestions.crewRoleId,
        AskQuestions.selectLegsId,
        AskQuestions.createMissingCrewId,
      ]);
    });

    test('a question with no default stays absent, not empty or zero', () {
      expect(AskQuestions.columnDate(const ['Date']).toJson(),
          isNot(contains('default')));
    });

    test('an unknown id is rejected by name', () {
      expect(
        () => readAnswers({'aircraf': 'ac-1'}, roster()),
        throwsA(isA<AskUserError>().having((e) => e.message, 'message',
            allOf(contains('Unknown answer'), contains('aircraf')))),
      );
    });

    test('a value outside the offered options is rejected', () {
      expect(
        () => readAnswers({AskQuestions.timeBasisId: 'zulu'}, roster()),
        throwsA(isA<AskUserError>().having((e) => e.message, 'message',
            allOf(contains('time_basis'), contains('got "zulu"')))),
      );
      expect(
        () => readAnswers({
          AskQuestions.selectLegsId: ['fl-1', 'fl-9'],
        }, roster()),
        throwsA(isA<AskUserError>()
            .having((e) => e.message, 'message', contains('fl-9'))),
      );
    });

    test('a value of the wrong type is rejected', () {
      expect(
        () => readAnswers({AskQuestions.createMissingCrewId: 'yes'}, roster()),
        throwsA(isA<AskUserError>().having((e) => e.message, 'message',
            contains('create_missing_crew must be true or false'))),
      );
      expect(
        () => readAnswers({AskQuestions.selectLegsId: 'fl-1'}, roster()),
        throwsA(isA<AskUserError>()
            .having((e) => e.message, 'message', contains('must be a list'))),
      );
    });

    test('a repeated multi-select option is rejected', () {
      expect(
        () => readAnswers({
          AskQuestions.selectLegsId: ['fl-1', 'fl-1'],
        }, roster()),
        throwsA(isA<AskUserError>()
            .having((e) => e.message, 'message', contains('must not repeat'))),
      );
    });

    test('a missing required answer is rejected', () {
      expect(
        () => readAnswers(const {}, [AskQuestions.confirmPlan]),
        throwsA(isA<AskUserError>().having(
            (e) => e.message, 'message', contains('confirm_plan is required'))),
      );
    });

    test('a complete form is read as answers', () {
      final result = readElicitResponse({
        'action': 'accept',
        'content': {
          AskQuestions.aircraftId: 'ac-1',
          AskQuestions.selectLegsId: ['fl-2'],
        },
      }, roster());
      expect(payloadOf(result), {
        'status': 'answered',
        'answers': {
          AskQuestions.aircraftId: 'ac-1',
          AskQuestions.timeBasisId: 'utc',
          AskQuestions.crewRoleId: 'pilotInCommand',
          AskQuestions.selectLegsId: ['fl-2'],
          AskQuestions.createMissingCrewId: false,
        },
        'defaulted': [
          AskQuestions.timeBasisId,
          AskQuestions.crewRoleId,
          AskQuestions.createMissingCrewId,
        ],
      });
    });

    test('nothing is defaulted when the caller answered everything', () {
      final read = readAnswers({
        AskQuestions.aircraftId: 'ac-1',
        AskQuestions.timeBasisId: 'local',
        AskQuestions.crewRoleId: 'copilot',
        AskQuestions.selectLegsId: ['fl-1'],
        AskQuestions.createMissingCrewId: true,
      }, roster());
      expect(read.defaulted, isEmpty);
      expect(read.answers[AskQuestions.crewRoleId], 'copilot');
    });

    test('answers without questions are checked against the catalogue', () {
      // A client with no form answers by id alone: the ids come from the
      // catalogue, so a typo is refused by name rather than guessed at.
      final read = readAnswers({
        AskQuestions.timeBasisId: 'local',
        AskQuestions.confirmPlanId: true,
      }, null);
      expect(read.answers, {
        AskQuestions.timeBasisId: 'local',
        AskQuestions.confirmPlanId: true,
      });
      expect(read.defaulted, isEmpty,
          reason: 'the questions that were not sent were not asked');
      expect(
        () => readAnswers({AskQuestions.timeBasisId: 'zulu'}, null),
        throwsA(isA<AskUserError>()
            .having((e) => e.message, 'message', contains('got "zulu"'))),
      );
      expect(
        () => readAnswers({'aircraf': 'ac-1'}, null),
        throwsA(isA<AskUserError>().having((e) => e.message, 'message',
            allOf(contains('Unknown answer'), contains('aircraf')))),
      );
    });

    test('decline and cancel are statuses, not errors', () {
      for (final (action, status) in [
        ('decline', 'declined'),
        ('cancel', 'cancelled'),
      ]) {
        final result = readElicitResponse({'action': action}, roster());
        expect(payloadOf(result), {'status': status});
        expect(result.isError, isFalse);
      }
    });

    test('a response that is not a form answer is refused by name', () {
      expect(
        () => readElicitResponse({'action': 'shrug'}, roster()),
        throwsA(isA<AskUserError>().having(
            (e) => e.message, 'message', contains('is not a form answer'))),
      );
    });
  });

  group('answers without questions', () {
    /// The end of a guided write: one optional question, then the confirmation
    /// that has to be given before anything is written.
    List<Question> writingFlow() => [
          AskQuestions.aircraft(const [QuestionOption('ac-1', 'VH-XZO')]),
          AskQuestions.confirmPlan,
        ];

    /// A store the server has just handed [questions] to, the way a client
    /// with no form is asked.
    Future<AskStateStore> asked(List<Question> questions) async {
      final state = AskStateStore();
      final result = await ask(
        {
          'questions': [for (final question in questions) question.toJson()],
        },
        state: state,
      );
      expect(payloadOf(result)['status'], 'needs_input');
      return state;
    }

    test('an empty answer set is refused, naming the required question',
        () async {
      final state = await asked(writingFlow());
      await expectLater(
        ask({'answers': const <String, Object?>{}}, state: state),
        throwsA(isA<AskUserError>()
            .having((error) => error.field, 'field', 'answers.confirm_plan')
            .having((error) => error.message, 'message',
                contains('confirm_plan is required'))),
      );
    });

    test('a partial answer set missing a required question is refused',
        () async {
      final state = await asked(writingFlow());
      await expectLater(
        ask({
          'answers': {AskQuestions.aircraftId: 'ac-1'}
        }, state: state),
        throwsA(isA<AskUserError>().having((error) => error.message, 'message',
            contains('confirm_plan is required'))),
      );
    });

    test('a complete answer set is answered', () async {
      final state = await asked(writingFlow());
      final result = await ask({
        'answers': {
          AskQuestions.aircraftId: 'ac-1',
          AskQuestions.confirmPlanId: true,
        },
      }, state: state);
      expect(payloadOf(result), {
        'status': 'answered',
        'answers': {
          AskQuestions.aircraftId: 'ac-1',
          AskQuestions.confirmPlanId: true,
        },
        'defaulted': <String>[],
      });
    });

    test('a required question no flow asked is not required', () async {
      // The roster asks nothing required. Answering it without resending the
      // questions must not be judged against column_date, duration_format,
      // confirm_plan or delete_rows, which belong to other flows.
      final state = await asked(roster());
      final result = await ask({
        'answers': {AskQuestions.aircraftId: 'ac-1'},
      }, state: state);
      expect(payloadOf(result), {
        'status': 'answered',
        'answers': {AskQuestions.aircraftId: 'ac-1'},
        'defaulted': <String>[],
      });
    });
  });

  group('question parsing', () {
    test('a malformed question is rejected by field', () {
      final cases = <String, Object?>{
        'questions must be a non-empty': const [],
        'questions[0] must be an object': const ['aircraft'],
        'questions[0].id must be a name': const [
          {'id': 'Aircraft', 'question': 'Q?', 'type': 'text'},
        ],
        'questions[0].question must be one sentence': const [
          {'id': 'aircraft', 'question': ' ', 'type': 'text'},
        ],
        'questions[0].type must be one of': const [
          {'id': 'aircraft', 'question': 'Q?', 'type': 'slider'},
        ],
        'questions[0].options is required': const [
          {'id': 'aircraft', 'question': 'Q?', 'type': 'choice'},
        ],
        'questions[0].options is not allowed': const [
          {
            'id': 'aircraft',
            'question': 'Q?',
            'type': 'boolean',
            'options': []
          },
        ],
        'questions[0].default must be one of': const [
          {
            'id': 'aircraft',
            'question': 'Q?',
            'type': 'choice',
            'options': [
              {'value': 'a'},
            ],
            'default': 'b',
          },
        ],
        'has unknown field': const [
          {'id': 'aircraft', 'question': 'Q?', 'type': 'text', 'kind': 'x'},
        ],
      };
      for (final entry in cases.entries) {
        expect(
          () => parseQuestions(entry.value),
          throwsA(isA<AskUserError>()
              .having((e) => e.message, 'message', contains(entry.key))),
          reason: '${entry.value} must be rejected',
        );
      }
    });

    test('duplicate ids are refused', () {
      expect(
        () => parseQuestions(const [
          {'id': 'aircraft', 'question': 'Q?', 'type': 'text'},
          {'id': 'aircraft', 'question': 'Q?', 'type': 'text'},
        ]),
        throwsA(isA<AskUserError>().having(
            (e) => e.message, 'message', contains('Duplicate question id'))),
      );
    });

    test('an option list keeps the value, label and description', () {
      final question = parseQuestions(const [
        {
          'id': 'aircraft',
          'header': 'Aircraft',
          'question': 'Which?',
          'type': 'choice',
          'options': [
            {'value': 'ac-1', 'label': 'VH-XZO', 'description': 'B738'},
            {'value': 'ac-2', 'label': 'VH-ABC'},
          ],
          'default': 'ac-2',
        },
      ]).single;
      expect(question.options.map((option) => option.value), ['ac-1', 'ac-2']);
      expect(question.options.first.label, 'VH-XZO');
      expect(question.options.first.description, 'B738');
      expect(question.defaultValue, 'ac-2');
      expect(question.required, isFalse);
    });
  });

  group('ask state', () {
    test('a token is spent on first use', () {
      final state = AskStateStore();
      final token = state.remember([AskQuestions.confirmPlan]);
      expect(state.pending, 1);
      expect(state.consume(token, [AskQuestions.confirmPlan]), isNull);
      expect(state.pending, 0);
      expect(state.consume(token, [AskQuestions.confirmPlan]),
          contains('no longer match'));
    });

    test('an unknown token is refused', () {
      expect(AskStateStore().consume('made-up', [AskQuestions.confirmPlan]),
          contains('no longer match'));
    });

    test('an expired token is refused', () {
      var now = DateTime(2026, 10, 28, 9);
      final state = AskStateStore(clock: () => now);
      final token = state.remember([AskQuestions.confirmPlan]);
      now = now.add(askStateTtl);
      expect(state.consume(token, [AskQuestions.confirmPlan]),
          contains('expired'));
      expect(state.pending, 0);
    });

    test('a token fits the same questions echoed in another order', () {
      final state = AskStateStore();
      final questions = roster();
      final token = state.remember(questions);
      expect(state.consume(token, questions.reversed.toList()), isNull,
          reason: 'a client may store and re-echo the questions as a set');
    });

    test('a token does not fit a different question set', () {
      final state = AskStateStore();
      final token = state.remember([AskQuestions.confirmPlan]);
      expect(state.consume(token, [AskQuestions.createMissingCrew]),
          contains('changed'));
      expect(state.pending, 0);
    });

    test('the same ids and kinds still fit after the wording changes', () {
      final state = AskStateStore();
      final token = state.remember([
        AskQuestions.aircraft(const [QuestionOption('ac-1', 'VH-XZO')]),
      ]);
      expect(
        state.consume(token, [
          AskQuestions.aircraft(const [
            QuestionOption('ac-2', 'VH-ABC'),
            QuestionOption('ac-1', 'VH-XZO'),
          ]),
        ]),
        isNull,
      );
    });

    test('tokens are long, random and url-safe', () {
      final state = AskStateStore();
      final tokens = {
        for (var i = 0; i < 50; i++) state.remember([AskQuestions.confirmPlan]),
      };
      expect(tokens, hasLength(50));
      for (final token in tokens) {
        expect(token, hasLength(greaterThanOrEqualTo(43)),
            reason: '32 bytes encode to 43 base64url characters');
        expect(token, matches(RegExp(r'^[A-Za-z0-9_-]+$')));
      }
    });
  });

  group('three paths', () {
    test('a stateless client that can elicit gets an input request', () async {
      final state = AskStateStore();
      final result = await ask(
        {
          'questions': [AskQuestions.confirmPlan.toJson()]
        },
        stateless: true,
        canElicit: true,
        state: state,
      );
      expect(result, isA<InputRequiredResult>());
      final json = result.toJson();
      expect(json['resultType'], 'input_required');
      expect(json['requestState'] as String, isNotEmpty);
      final request =
          (json['inputRequests'] as Map)['questions'] as Map<String, dynamic>;
      expect(request['method'], 'elicitation/create');
      final params = request['params'] as Map<String, dynamic>;
      expect(params['mode'], 'form');
      expect(params['message'], isA<String>());
      expect((params['requestedSchema'] as Map)['properties'],
          contains(AskQuestions.confirmPlanId));
      expect(state.pending, 1);
    });

    test('the retry with inputResponses returns the answers', () async {
      final state = AskStateStore();
      final questions = [AskQuestions.confirmPlan.toJson()];
      final first = await ask(
        {'questions': questions},
        stateless: true,
        canElicit: true,
        state: state,
      );
      final token = first.toJson()['requestState'] as String;
      final retry = await ask(
        {'questions': questions},
        stateless: true,
        canElicit: true,
        state: state,
        requestState: token,
        inputResponses: {
          askUserInputKey: InputResponse.fromJson({
            'action': 'accept',
            'content': {AskQuestions.confirmPlanId: true},
          }),
        },
      );
      expect(payloadOf(retry), {
        'status': 'answered',
        'answers': {AskQuestions.confirmPlanId: true},
        'defaulted': <String>[],
      });
    });

    test('the retry is accepted when the questions come back reordered',
        () async {
      final state = AskStateStore();
      final questions = [
        AskQuestions.confirmPlan.toJson(),
        AskQuestions.createMissingCrew.toJson(),
      ];
      final first = await ask(
        {'questions': questions},
        stateless: true,
        canElicit: true,
        state: state,
      );
      final token = first.toJson()['requestState'] as String;
      // A client that keeps the asked questions in a set may echo them in any
      // order: the same questions are still the same questions.
      final retry = await ask(
        {'questions': questions.reversed.toList()},
        stateless: true,
        canElicit: true,
        state: state,
        requestState: token,
        inputResponses: {
          askUserInputKey: InputResponse.fromJson({
            'action': 'accept',
            'content': {
              AskQuestions.confirmPlanId: true,
              AskQuestions.createMissingCrewId: false,
            },
          }),
        },
      );
      expect(payloadOf(retry), {
        'status': 'answered',
        'answers': {
          AskQuestions.confirmPlanId: true,
          AskQuestions.createMissingCrewId: false,
        },
        'defaulted': <String>[],
      });
      expect(state.pending, 0, reason: 'the token was spent, not lost');
    });

    test('a replayed token is refused rather than answered twice', () async {
      final state = AskStateStore();
      final questions = [AskQuestions.confirmPlan.toJson()];
      final first = await ask(
        {'questions': questions},
        stateless: true,
        canElicit: true,
        state: state,
      );
      final token = first.toJson()['requestState'] as String;
      InputResponses accepted() => {
            askUserInputKey: InputResponse.fromJson({
              'action': 'accept',
              'content': {AskQuestions.confirmPlanId: true},
            }),
          };
      await ask({'questions': questions},
          stateless: true,
          canElicit: true,
          state: state,
          requestState: token,
          inputResponses: accepted());
      final replay = await ask({'questions': questions},
          stateless: true,
          canElicit: true,
          state: state,
          requestState: token,
          inputResponses: accepted());
      final payload = payloadOf(replay);
      expect(payload['status'], 'needs_input');
      expect(payload, isNot(contains('answers')));
      expect(payload['reason'], contains('no longer match'));
    });

    test('a legacy client that can elicit is asked inside the call', () async {
      ElicitRequest? asked;
      final result = await askUser(
        {
          'questions': [AskQuestions.confirmPlan.toJson()]
        },
        stateless: false,
        canElicit: true,
        state: AskStateStore(),
        elicit: (request) async {
          asked = request;
          return const ElicitResult(
            action: 'accept',
            content: {AskQuestions.confirmPlanId: true},
          );
        },
      );
      expect(asked, isNotNull);
      expect(asked!.isFormMode, isTrue);
      expect(asked!.requestedSchema!.toJson()['properties'],
          contains(AskQuestions.confirmPlanId));
      expect(payloadOf(result), {
        'status': 'answered',
        'answers': {AskQuestions.confirmPlanId: true},
        'defaulted': <String>[],
      });
    });

    test('a client without elicitation gets the same questions as data',
        () async {
      final questions = [
        AskQuestions.aircraft(const [QuestionOption('ac-1', 'VH-XZO')])
            .toJson(),
        AskQuestions.timeBasis.toJson(),
      ];
      for (final stateless in [true, false]) {
        final fallback =
            await ask({'questions': questions}, stateless: stateless);
        final payload = payloadOf(fallback);
        expect(payload['status'], 'needs_input');
        expect(payload['questions'], questions,
            reason: 'the fallback asks exactly what the form would have');
        expect(payload, isNot(contains('reason')));

        final answers = await ask({
          'questions': questions,
          'answers': {AskQuestions.aircraftId: 'ac-1'},
        }, stateless: stateless);
        expect(payloadOf(answers), {
          'status': 'answered',
          'answers': {
            AskQuestions.aircraftId: 'ac-1',
            AskQuestions.timeBasisId: 'utc',
          },
          'defaulted': [AskQuestions.timeBasisId],
        });
      }
    });

    test('the documented shape completes without resending the questions',
        () async {
      // Issue #6's second criterion: a client with no form answers with the
      // answers alone, over the connection that has no form capability.
      for (final stateless in [true, false]) {
        final result = await ask({
          'answers': {AskQuestions.aircraftId: 'ac-1'},
        }, stateless: stateless);
        expect(payloadOf(result), {
          'status': 'answered',
          'answers': {AskQuestions.aircraftId: 'ac-1'},
          'defaulted': <String>[],
        });

        final declined = await ask({'action': 'decline'}, stateless: stateless);
        expect(payloadOf(declined), {'status': 'declined'});
        expect((declined as CallToolResult).isError, isFalse);

        final cancelled = await ask({'action': 'cancel'}, stateless: stateless);
        expect(payloadOf(cancelled), {'status': 'cancelled'});
      }
    });

    test('the fallback completes from answers without server state', () async {
      final state = AskStateStore();
      final result = await ask(
        {
          'questions': [AskQuestions.confirmPlan.toJson()],
          'answers': {AskQuestions.confirmPlanId: true},
        },
        canElicit: true,
        state: state,
      );
      expect(payloadOf(result), {
        'status': 'answered',
        'answers': {AskQuestions.confirmPlanId: true},
        'defaulted': <String>[],
      });
      expect(state.pending, 0);
    });

    test('the fallback reports a decline and a cancel', () async {
      for (final (action, status) in [
        ('decline', 'declined'),
        ('cancel', 'cancelled'),
      ]) {
        final result = await ask({
          'questions': [AskQuestions.confirmPlan.toJson()],
          'action': action,
        });
        expect(payloadOf(result), {'status': status});
      }
    });

    test('a stateless client without elicitation never gets a token', () async {
      final state = AskStateStore();
      final result = await ask(
        {
          'questions': [AskQuestions.confirmPlan.toJson()]
        },
        stateless: true,
        state: state,
      );
      expect(result, isA<CallToolResult>());
      expect(state.pending, 0);
    });
  });

  group('boundary', () {
    test('an accept with no answers and no questions is refused', () async {
      await expectLater(
        ask({'action': 'accept'}),
        throwsA(isA<AskUserError>().having(
            (e) => e.message, 'message', contains('accepting needs answers'))),
      );
    });

    test('an accept action with no answers is not an answer', () async {
      await expectLater(
        ask({
          'questions': [AskQuestions.confirmPlan.toJson()],
          'action': 'accept',
        }),
        throwsA(isA<AskUserError>().having(
            (e) => e.message, 'message', contains('confirm_plan is required'))),
      );
    });

    test('state without responses is refused', () async {
      await expectLater(
        ask(
          {
            'questions': [AskQuestions.confirmPlan.toJson()]
          },
          stateless: true,
          canElicit: true,
          requestState: 'token',
        ),
        throwsA(isA<AskUserError>().having(
            (e) => e.message, 'message', contains('without inputResponses'))),
      );
    });

    test('responses without state are refused', () async {
      await expectLater(
        ask(
          {
            'questions': [AskQuestions.confirmPlan.toJson()]
          },
          inputResponses: {
            askUserInputKey: InputResponse.fromJson({
              'action': 'accept',
              'content': {AskQuestions.confirmPlanId: true},
            }),
          },
        ),
        throwsA(isA<AskUserError>().having((e) => e.message, 'message',
            contains('requires the requestState'))),
      );
    });

    test('a response under another input key is refused', () async {
      final state = AskStateStore();
      final questions = [AskQuestions.confirmPlan.toJson()];
      final token = state.remember(parseQuestions(questions));
      await expectLater(
        ask(
          {'questions': questions},
          inputResponses: {
            'other': InputResponse.fromJson({
              'action': 'accept',
              'content': {AskQuestions.confirmPlanId: true},
            }),
          },
          requestState: token,
          state: state,
        ),
        throwsA(isA<AskUserError>()
            .having((e) => e.message, 'message', contains('is missing'))),
      );
    });

    test('answers that are not an object are refused', () async {
      await expectLater(
        ask({
          'questions': [AskQuestions.confirmPlan.toJson()],
          'answers': ['yes'],
        }),
        throwsA(isA<AskUserError>().having((e) => e.message, 'message',
            contains('answers must be an object'))),
      );
    });
  });
}
