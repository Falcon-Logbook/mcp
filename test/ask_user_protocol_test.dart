import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'support/harness.dart';

/// The two roster questions, as a caller sends them.
final List<Map<String, dynamic>> questions = [
  {
    'id': 'aircraft',
    'header': 'Aircraft',
    'question': 'Which aircraft should these legs go on?',
    'type': 'choice',
    'options': [
      {'value': 'ac-1', 'label': 'VH-XZO', 'description': 'B738'},
      {'value': '', 'label': 'Leave blank'},
    ],
    'default': '',
  },
  {
    'id': 'time_basis',
    'header': 'Time',
    'question': 'Are these times UTC, local base time, or airport local?',
    'type': 'choice',
    'options': [
      {'value': 'utc', 'label': 'UTC'},
      {'value': 'local', 'label': 'Local base time'},
      {'value': 'airport_local', 'label': 'Airport local'},
    ],
    'default': 'utc',
  },
];

Map<String, dynamic> resultOf(Map<String, dynamic> response) =>
    response['result'] as Map<String, dynamic>;

void main() {
  late Directory tempDir;
  late String dbPath;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('falcon_mcp_ask_test');
    dbPath = createFixture('${tempDir.path}/falcon_db.sqlite');
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  test('ask_user is listed in read-only mode', () async {
    final server = await McpProcess.start(dbPath);
    addTearDown(() async {
      await server.stop();
    });

    expect(await server.toolNames(), contains('ask_user'));

    final help = await server.send('prompts/get', {'name': 'falcon_help'});
    final messages = (help['result'] as Map)['messages'] as List;
    final text = ((messages.single as Map)['content'] as Map)['text'] as String;
    // The rewritten help speaks to a pilot, so ask_user appears as the thing it
    // does, a list to pick from, never as a tool name.
    expect(text, contains('pick from a list'));
    expect(text, isNot(contains('ask_user')));
    // The prompt is read by a pilot, so it must not name the protocol.
    expect(text, isNot(contains('InputRequired')));
    expect(text, isNot(contains('elicitation')));
  });

  test('a 2026-07-28 client with elicitation completes a form over the wire',
      () async {
    final server = await McpProcess.startStateless(
      dbPath,
      clientCapabilities: {
        'elicitation': {
          'form': <String, dynamic>{},
        },
      },
    );
    addTearDown(() async {
      await server.stop();
    });

    final first = await server.callRaw('ask_user', {'questions': questions});
    final asked = resultOf(first);
    expect(asked['resultType'], 'input_required',
        reason: 'a stateless tool answers with an input request: $asked');

    final requests = asked['inputRequests'] as Map<String, dynamic>;
    expect(requests.keys, ['questions']);
    final request = requests['questions'] as Map<String, dynamic>;
    expect(request['method'], 'elicitation/create');
    final params = request['params'] as Map<String, dynamic>;
    expect(params['mode'], 'form');
    expect(params['requestedSchema'], {
      'type': 'object',
      'properties': {
        'aircraft': {
          'title': 'Aircraft',
          'description': 'Which aircraft should these legs go on?',
          'default': '',
          'type': 'string',
          'oneOf': [
            {'const': 'ac-1', 'title': 'VH-XZO (B738)'},
            {'const': '', 'title': 'Leave blank'},
          ],
        },
        'time_basis': {
          'title': 'Time',
          'description': 'Are these times UTC, local base time, or airport '
              'local?',
          'default': 'utc',
          'type': 'string',
          'oneOf': [
            {'const': 'utc', 'title': 'UTC'},
            {'const': 'local', 'title': 'Local base time'},
            {'const': 'airport_local', 'title': 'Airport local'},
          ],
        },
      },
    });

    final state = asked['requestState'] as String;
    expect(state, isNotEmpty);

    // The retry: a new JSON-RPC id, the same arguments, the state echoed back
    // and the answers as a sibling of name and arguments.
    final second = await server.callRaw(
      'ask_user',
      {'questions': questions},
      extra: {
        'requestState': state,
        'inputResponses': {
          'questions': {
            'action': 'accept',
            'content': {'aircraft': 'ac-1'},
          },
        },
      },
    );
    expect(second['id'], isNot(first['id']));
    final answered = resultOf(second);
    expect(answered['structuredContent'], {
      'status': 'answered',
      'answers': {'aircraft': 'ac-1', 'time_basis': 'utc'},
      'defaulted': ['time_basis'],
    });
    expect(answered['isError'], isNot(true));
  });

  test('a 2026-07-28 client without elicitation completes through answers',
      () async {
    final server = await McpProcess.startStateless(dbPath);
    addTearDown(() async {
      await server.stop();
    });

    final first = await server.callRaw('ask_user', {'questions': questions});
    final needs = resultOf(first);
    expect(needs['structuredContent'], {
      'status': 'needs_input',
      'questions': questions,
    });
    expect(needs['isError'], isNot(true));

    final second = await server.callRaw('ask_user', {
      'questions': questions,
      'answers': {'aircraft': 'ac-1', 'time_basis': 'airport_local'},
    });
    expect(resultOf(second)['structuredContent'], {
      'status': 'answered',
      'answers': {'aircraft': 'ac-1', 'time_basis': 'airport_local'},
      'defaulted': <String>[],
    });

    // The shape issue #6 documents: the answers alone, no questions resent, on
    // the connection that has no form to show them in. This client is the one
    // that needs it, so this test is where it has to keep working.
    final alone = resultOf(await server.callRaw('ask_user', {
      'answers': {'aircraft': 'ac-1'},
    }));
    expect(alone['isError'], isNot(true), reason: '${alone['content']}');
    expect(alone['structuredContent'], {
      'status': 'answered',
      'answers': {'aircraft': 'ac-1'},
      'defaulted': <String>[],
    });

    final declined =
        resultOf(await server.callRaw('ask_user', {'action': 'decline'}));
    expect(declined['isError'], isNot(true),
        reason: 'a decline is an answer, not a failure');
    expect(declined['structuredContent'], {'status': 'declined'});

    final cancelled =
        resultOf(await server.callRaw('ask_user', {'action': 'cancel'}));
    expect(cancelled['structuredContent'], {'status': 'cancelled'});
  });

  test('a required question cannot be skipped by not resending the questions',
      () async {
    final server = await McpProcess.startStateless(dbPath);
    addTearDown(() async {
      await server.stop();
    });

    // The confirmation a guided write asks before it changes the logbook.
    final writingFlow = [
      ...questions,
      {
        'id': 'confirm_plan',
        'header': 'Confirm',
        'question': 'Review the plan above and confirm',
        'type': 'boolean',
        'default': false,
        'required': true,
      },
    ];

    final asked =
        resultOf(await server.callRaw('ask_user', {'questions': writingFlow}));
    expect((asked['structuredContent'] as Map)['status'], 'needs_input');

    // Answers alone, the shape issue #6 documents: the flow's required
    // question is still enforced, or a flow that reads `answered` as consent
    // would write having never been confirmed.
    Map<String, dynamic> envelopeOf(String payload) =>
        jsonDecode(payload) as Map<String, dynamic>;

    final empty =
        await server.call('ask_user', {'answers': <String, dynamic>{}});
    expect(empty.isError, isTrue, reason: '${empty.payload}');
    expect(
        envelopeOf(empty.payload as String)['field'], 'answers.confirm_plan');
    expect(envelopeOf(empty.payload as String)['detail'],
        contains('confirm_plan is required'));

    final partial = await server.call('ask_user', {
      'answers': {'aircraft': 'ac-1'},
    });
    expect(partial.isError, isTrue, reason: '${partial.payload}');

    final complete = await server.call('ask_user', {
      'answers': {'aircraft': 'ac-1', 'confirm_plan': true},
    });
    expect(complete.isError, isFalse, reason: '${complete.payload}');
    expect(complete.payload, {
      'status': 'answered',
      'answers': {'aircraft': 'ac-1', 'confirm_plan': true},
      'defaulted': <String>[],
    });
  });

  test('a multi-select answer survives the round trip', () async {
    final server = await McpProcess.startStateless(
      dbPath,
      clientCapabilities: {
        'elicitation': {
          'form': <String, dynamic>{},
        },
      },
    );
    addTearDown(() async {
      await server.stop();
    });

    final legs = [
      {
        'id': 'select_legs',
        'header': 'Legs',
        'question': 'Which legs should I include?',
        'type': 'multi',
        'options': [
          {'value': 'fl-1', 'label': 'YSSY - NZQN'},
          {'value': 'fl-2', 'label': 'YSBK - YSSY'},
        ],
        'default': ['fl-1', 'fl-2'],
      },
    ];

    final asked =
        resultOf(await server.callRaw('ask_user', {'questions': legs}));
    final schema = ((asked['inputRequests'] as Map)['questions']
        as Map)['params']['requestedSchema'] as Map;
    expect((schema['properties'] as Map)['select_legs'], {
      'title': 'Legs',
      'description': 'Which legs should I include?',
      'default': ['fl-1', 'fl-2'],
      'type': 'array',
      'items': {
        'type': 'string',
        'anyOf': [
          {'const': 'fl-1', 'title': 'YSSY - NZQN'},
          {'const': 'fl-2', 'title': 'YSBK - YSSY'},
        ],
      },
    });

    final answered = resultOf(await server.callRaw(
      'ask_user',
      {'questions': legs},
      extra: {
        'requestState': asked['requestState'],
        'inputResponses': {
          'questions': {
            'action': 'accept',
            'content': {
              'select_legs': ['fl-2'],
            },
          },
        },
      },
    ));
    expect(answered['structuredContent'], {
      'status': 'answered',
      'answers': {
        'select_legs': ['fl-2'],
      },
      'defaulted': <String>[],
    });
  });

  test('decline and cancel come back as statuses on a form client', () async {
    final server = await McpProcess.startStateless(
      dbPath,
      clientCapabilities: {
        'elicitation': {
          'form': <String, dynamic>{},
        },
      },
    );
    addTearDown(() async {
      await server.stop();
    });

    for (final (action, status) in [
      ('decline', 'declined'),
      ('cancel', 'cancelled'),
    ]) {
      final asked = resultOf(await server.callRaw('ask_user', {
        'questions': questions,
      }));
      final retry = await server.callRaw(
        'ask_user',
        {'questions': questions},
        extra: {
          'requestState': asked['requestState'],
          'inputResponses': {
            'questions': {'action': action},
          },
        },
      );
      final answered = resultOf(retry);
      expect(answered['isError'], isNot(true),
          reason: 'a $action is an answer, not a failure');
      expect(answered['structuredContent'], {'status': status});
    }
  });

  test('a tampered or replayed state is refused, not answered', () async {
    final server = await McpProcess.startStateless(
      dbPath,
      clientCapabilities: {
        'elicitation': {
          'form': <String, dynamic>{},
        },
      },
    );
    addTearDown(() async {
      await server.stop();
    });

    Map<String, dynamic> accept() => {
          'questions': {
            'action': 'accept',
            'content': {'aircraft': 'ac-1'},
          },
        };

    // A state the server never issued: the answers are dropped and the
    // questions come back, rather than being accepted.
    final tampered = resultOf(await server.callRaw(
      'ask_user',
      {'questions': questions},
      extra: {'requestState': 'not-a-real-token', 'inputResponses': accept()},
    ));
    expect(tampered['structuredContent']['status'], 'needs_input');
    expect(
        tampered['structuredContent']['reason'], contains('no longer match'));
    expect(tampered['structuredContent'], isNot(contains('answers')));

    // A state that was already spent: same again.
    final asked = resultOf(await server.callRaw('ask_user', {
      'questions': questions,
    }));
    final state = asked['requestState'] as String;
    final first = resultOf(await server.callRaw(
      'ask_user',
      {'questions': questions},
      extra: {'requestState': state, 'inputResponses': accept()},
    ));
    expect(first['structuredContent']['status'], 'answered');
    final replay = resultOf(await server.callRaw(
      'ask_user',
      {'questions': questions},
      extra: {'requestState': state, 'inputResponses': accept()},
    ));
    expect(replay['structuredContent']['status'], 'needs_input');
    expect(replay['structuredContent'], isNot(contains('answers')));
  });

  test('a legacy client with elicitation is asked inside the call', () async {
    final server = await McpProcess.start(dbPath, capabilities: {
      'elicitation': {
        'form': <String, dynamic>{},
      },
    });
    addTearDown(() async {
      await server.stop();
    });

    final callId = await server.write('tools/call', {
      'name': 'ask_user',
      'arguments': {'questions': questions},
    });

    final elicit = await server.read();
    expect(elicit['method'], 'elicitation/create',
        reason: 'a 2025-06-18 client sees a server-initiated request');
    final params = elicit['params'] as Map<String, dynamic>;
    final requested = params['requestedSchema'] as Map<String, dynamic>;
    expect((requested['properties'] as Map).keys, ['aircraft', 'time_basis']);

    await server.reply(elicit, {
      'action': 'accept',
      'content': {'aircraft': 'ac-1'},
    });
    final response = await server.read();
    expect(response['id'], callId);
    expect(resultOf(response)['structuredContent'], {
      'status': 'answered',
      'answers': {'aircraft': 'ac-1', 'time_basis': 'utc'},
      'defaulted': ['time_basis'],
    });
  });

  test('a legacy client without elicitation gets needs_input', () async {
    final server = await McpProcess.start(dbPath);
    addTearDown(() async {
      await server.stop();
    });

    final call = await server.call('ask_user', {'questions': questions});
    expect(call.isError, isFalse);
    expect(call.payload, {
      'status': 'needs_input',
      'questions': questions,
    });

    final answered = await server.call('ask_user', {
      'questions': questions,
      'answers': {'aircraft': 'ac-1'},
    });
    expect(answered.payload, {
      'status': 'answered',
      'answers': {'aircraft': 'ac-1', 'time_basis': 'utc'},
      'defaulted': ['time_basis'],
    });
  });

  test('a bad question is a tool error naming the field', () async {
    final server = await McpProcess.start(dbPath);
    addTearDown(() async {
      await server.stop();
    });

    // The same envelope every other tool refuses with: a code, the field at
    // fault and one sentence, so a caller parses one shape either way.
    Map<String, dynamic> envelopeOf(({bool isError, Object? payload}) call) {
      expect(call.isError, isTrue,
          reason: 'expected a refusal: ${call.payload}');
      return jsonDecode(call.payload as String) as Map<String, dynamic>;
    }

    final missing = envelopeOf(await server.call('ask_user', {
      'questions': [
        {'id': 'aircraft', 'question': 'Which?', 'type': 'choice'},
      ],
    }));
    expect(missing['error'], 'invalid_value');
    expect(missing['field'], 'questions[0].options');
    expect(missing['detail'], contains('questions[0].options is required'));
    expect(missing.keys.toSet(), {'error', 'field', 'detail'});

    final unknown = envelopeOf(await server.call('ask_user', {
      'questions': questions,
      'answers': {'aircraf': 'ac-1'},
    }));
    expect(unknown['error'], 'invalid_value');
    expect(unknown['field'], 'answers');
    expect(unknown['detail'], contains('Unknown answer'));
    expect(unknown['detail'], contains('aircraf'));

    final badValue = envelopeOf(await server.call('ask_user', {
      'questions': questions,
      'answers': {'aircraft': 'ac-9'},
    }));
    expect(badValue['error'], 'invalid_value');
    expect(badValue['field'], 'answers.aircraft');
    expect(badValue['detail'], contains('ac-9'));

    // An argument the tool does not write is the same refusal as elsewhere:
    // unknown_field, the field named, and the tool named with it.
    final typo = envelopeOf(await server.call('ask_user', {
      'question': questions,
    }));
    expect(typo['error'], 'unknown_field');
    expect(typo['field'], 'question');
    expect(typo['tool'], 'ask_user');
    expect(typo['detail'], 'accepts action, answers, questions');
  });

  test('ask_user writes nothing', () async {
    final server = await McpProcess.startStateless(dbPath);
    addTearDown(() async {
      await server.stop();
    });

    final before = withFixtureDb(dbPath,
        (db) => db.select('SELECT count(*) AS n FROM flights').single['n']);

    await server.callRaw('ask_user', {'questions': questions});
    await server.callRaw('ask_user', {
      'questions': questions,
      'answers': {'aircraft': 'ac-1'},
    });

    final after = withFixtureDb(dbPath,
        (db) => db.select('SELECT count(*) AS n FROM flights').single['n']);
    expect(after, before);
  });
}
