import 'package:mcp_dart/mcp_dart.dart';

/// The kinds of question a form can render.
///
/// The protocol allows a flat object of primitive properties only, so these are
/// the only four shapes `ask_user` can ask. Nested objects and arrays of
/// objects are refused by the SDK when the request is built.
enum QuestionType { choice, multi, boolean, text }

/// One selectable answer of a [QuestionType.choice] or [QuestionType.multi].
class QuestionOption {
  const QuestionOption(this.value, this.label, {this.description});

  /// What the flow receives when this option is chosen.
  final String value;

  /// What the pilot reads.
  final String label;

  /// An optional second line explaining the option.
  final String? description;

  /// The label a single choice shows.
  ///
  /// An entry of `oneOf` allows a const and a title only, so an explanation
  /// would be dropped there; a multiple choice keeps it inside `anyOf`. Folding
  /// it into the label is what makes the catalogue's explanations reach a form
  /// on both, and it stays out of the question text so a label is not repeated.
  String get formLabel => description == null ? label : '$label ($description)';

  Map<String, dynamic> toJson() => {
        'value': value,
        'label': label,
        if (description != null) 'description': description,
      };
}

/// One question in a form.
///
/// [id] is the property name in the schema and the key of the answer, so it
/// must be unique within a form and stable across releases: a flow reads its
/// answer back by id.
class Question {
  const Question({
    required this.id,
    required this.question,
    required this.type,
    this.header,
    this.options = const [],
    this.defaultValue,
    this.required = false,
  });

  final String id;

  /// A short label above the field, when the question is too long for one.
  final String? header;

  /// One sentence the pilot answers.
  final String question;

  final QuestionType type;
  final List<QuestionOption> options;

  /// The value the form starts with. Advisory: a client may ignore it, so the
  /// reader applies it again when an optional answer is missing.
  final Object? defaultValue;

  /// Whether the answer must be present for the form to be accepted.
  final bool required;

  /// The same question with no options.
  ///
  /// The catalogue cannot know the aircraft, legs or columns a flow offered, so
  /// a call that answers without resending the questions is checked against the
  /// id and the type of this question alone. A choice with no options is
  /// therefore not a form question: [elicitRequest] refuses one.
  Question withoutOptions() => Question(
        id: id,
        header: header,
        question: question,
        type: type,
        defaultValue: defaultValue,
        required: required,
      );

  /// The question as it travels to a caller, so a fallback client can send the
  /// same questions back with its answers.
  Map<String, dynamic> toJson() => {
        'id': id,
        if (header != null) 'header': header,
        'question': question,
        'type': type.name,
        if (options.isNotEmpty)
          'options': [for (final o in options) o.toJson()],
        if (defaultValue != null) 'default': defaultValue,
        if (required) 'required': true,
      };

  /// One property of the form schema.
  ///
  /// The shapes here are the ones the protocol accepts: a string with `oneOf`
  /// const/title options for a single choice, an array of the same for a
  /// multiple choice, and a bare boolean or string. Anything else is refused
  /// when the request is built.
  JsonSchema toElicitationSchema() {
    switch (type) {
      case QuestionType.choice:
        return JsonSchema.fromJson({
          'type': 'string',
          if (header != null) 'title': header,
          'description': question,
          'oneOf': [
            for (final option in options)
              {'const': option.value, 'title': option.formLabel},
          ],
          if (defaultValue != null) 'default': defaultValue,
        });
      case QuestionType.multi:
        return JsonSchema.array(
          title: header,
          description: question,
          items: JsonEnum([
            for (final option in options)
              {
                'value': option.value,
                'title': option.label,
                if (option.description != null)
                  'description': option.description,
              },
          ]),
          defaultValue: switch (defaultValue) {
            final List<dynamic> values => values,
            _ => null,
          },
        );
      case QuestionType.boolean:
        return JsonSchema.boolean(
          title: header,
          description: question,
          defaultValue: switch (defaultValue) {
            final bool value => value,
            _ => null,
          },
        );
      case QuestionType.text:
        return JsonSchema.string(
          title: header,
          description: question,
          defaultValue: switch (defaultValue) {
            final String value => value,
            _ => null,
          },
        );
    }
  }
}

/// The questions the guided flows ask, in one place.
///
/// One vocabulary for "which aircraft" and "are these times UTC" means #3, #4
/// and the tidy-up cannot drift apart in wording or in answer ids. The ids are
/// the contract: a flow reads an answer by id, so changing one breaks every
/// caller.
abstract final class AskQuestions {
  static const aircraftId = 'aircraft';
  static const timeBasisId = 'time_basis';
  static const crewRoleId = 'crew_role';
  static const selectLegsId = 'select_legs';
  static const createMissingCrewId = 'create_missing_crew';
  static const columnDateId = 'column_date';
  static const durationFormatId = 'duration_format';
  static const unmappedColumnId = 'unmapped_column';
  static const confirmPlanId = 'confirm_plan';
  static const deleteRowsId = 'delete_rows';

  /// Every id above, for the test that keeps them unique and schema-safe.
  static const List<String> ids = [
    aircraftId,
    timeBasisId,
    crewRoleId,
    selectLegsId,
    createMissingCrewId,
    columnDateId,
    durationFormatId,
    unmappedColumnId,
    confirmPlanId,
    deleteRowsId,
  ];

  /// The empty value of the aircraft choice: keep the aircraft column blank.
  static const leaveBlank = '';

  /// Which aircraft these legs go on.
  ///
  /// [options] come from a local-scope aircraft read (owner null or "local"),
  /// one per aircraft. This is the picker, so offering another device's
  /// aircraft here would let a flight be filed against an aircraft the pilot
  /// does not have. "Leave blank" is added here rather than by the flow, so a
  /// logbook with no aircraft still produces a question that can be answered.
  static Question aircraft(List<QuestionOption> options) => Question(
        id: aircraftId,
        header: 'Aircraft',
        question: 'Which aircraft should these legs go on?',
        type: QuestionType.choice,
        options: [
          ...options,
          const QuestionOption(leaveBlank, 'Leave blank'),
        ],
        defaultValue: leaveBlank,
      );

  /// How to read the times in the source.
  ///
  /// airport_local is an interpretation hint, not a stored value: the app
  /// stores calc_time_mode as utc, local, time or hobbsTacho, so a flow that
  /// writes this answer converts the times and maps airport_local to local (or
  /// to time, when the source holds durations).
  static const timeBasis = Question(
    id: timeBasisId,
    header: 'Time',
    question: 'Are these times UTC, local base time, or airport local?',
    type: QuestionType.choice,
    options: [
      QuestionOption('utc', 'UTC', description: 'Coordinated Universal Time'),
      QuestionOption('local', 'Local base time',
          description: 'The time zone your base is in'),
      QuestionOption('airport_local', 'Airport local',
          description: 'Each airport in its own time zone'),
    ],
    defaultValue: 'utc',
  );

  /// The pilot's role on the legs. Values are the stored crew_role values.
  static const crewRole = Question(
    id: crewRoleId,
    header: 'Your role',
    question: 'Are you PIC on these legs?',
    type: QuestionType.choice,
    options: [
      QuestionOption('pilotInCommand', 'PIC', description: 'Pilot in Command'),
      QuestionOption('copilot', 'Co-pilot'),
      QuestionOption('student', 'Student'),
    ],
    defaultValue: 'pilotInCommand',
  );

  /// Which legs of an import to keep. Defaults to all of them.
  static Question selectLegs(List<QuestionOption> legs) => Question(
        id: selectLegsId,
        header: 'Legs',
        question: 'Which legs should I include?',
        type: QuestionType.multi,
        options: legs,
        defaultValue: [for (final leg in legs) leg.value],
      );

  /// Whether crew names that match nobody become crew members.
  static const createMissingCrew = Question(
    id: createMissingCrewId,
    header: 'Crew',
    question: 'Create crew members that do not exist?',
    type: QuestionType.boolean,
    defaultValue: false,
  );

  /// Which column of an imported file holds the date.
  static Question columnDate(List<String> headers) => Question(
        id: columnDateId,
        header: 'Date column',
        question: 'Which column is the date?',
        type: QuestionType.choice,
        options: [
          for (final header in headers) QuestionOption(header, header),
        ],
        required: true,
      );

  /// How durations in an imported file are written.
  static const durationFormat = Question(
    id: durationFormatId,
    header: 'Durations',
    question: 'Durations are decimal hours or HH:MM?',
    type: QuestionType.choice,
    options: [
      QuestionOption('hours', 'Decimal hours', description: 'For example 1.5'),
      QuestionOption('hhmm', 'HH:MM', description: 'For example 1:30'),
    ],
    required: true,
  );

  /// What to do with a column of an imported file that maps to nothing.
  ///
  /// The alternatives are the storage the app actually has, not invented ones.
  static Question unmappedColumn(String column) => Question(
        id: unmappedColumnId,
        header: 'Unmapped column',
        question: 'What should I do with "$column"?',
        type: QuestionType.choice,
        options: const [
          QuestionOption('ignore', 'Ignore it'),
          QuestionOption('custom_columns', 'Keep it as a custom column',
              description: 'Stored with the flight, shown in its own column'),
          QuestionOption('approach_details', 'Add to approach details',
              description: 'Appended to the approaches note'),
        ],
        defaultValue: 'ignore',
      );

  /// The confirmation a guided flow asks before it writes.
  static const confirmPlan = Question(
    id: confirmPlanId,
    header: 'Confirm',
    question: 'Review the plan above and confirm',
    type: QuestionType.boolean,
    defaultValue: false,
    required: true,
  );

  /// The confirmation before a delete, which nothing can undo.
  static Question deleteRows(int rows) => Question(
        id: deleteRowsId,
        header: 'Delete',
        question: 'Delete $rows ${rows == 1 ? 'row' : 'rows'}? '
            'This cannot be undone',
        type: QuestionType.boolean,
        defaultValue: false,
        required: true,
      );

  /// The catalogue question with [id], or null when no question has that id.
  ///
  /// This is how a call that answers without resending the questions is
  /// checked: the ids above are the ones the tool offers, and each carries the
  /// type its answer must have. The questions whose options come from a logbook
  /// or an imported file have none here, because only the flow that asked knows
  /// them, so their answers are checked for id and type alone.
  static Question? byId(String id) => _byId[id];

  static final Map<String, Question> _byId = {
    aircraftId: aircraft(const []).withoutOptions(),
    timeBasisId: timeBasis,
    crewRoleId: crewRole,
    selectLegsId: selectLegs(const []).withoutOptions(),
    createMissingCrewId: createMissingCrew,
    columnDateId: columnDate(const []).withoutOptions(),
    durationFormatId: durationFormat,
    unmappedColumnId: unmappedColumn(''),
    confirmPlanId: confirmPlan,
    deleteRowsId: deleteRows(0),
  };
}
