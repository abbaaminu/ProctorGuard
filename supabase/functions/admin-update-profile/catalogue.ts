// =====================================================================
// The academic catalogue, as `admin-update-profile` validates against it
// =====================================================================
// The columns themselves are free text (`profiles.faculty / department /
// level`, see `supabase/migrations/academic_targeting.sql`), which is what lets
// an import carry a spelling this build has never heard of. That freedom is fine
// for *storing* a label and wrong for *correcting* one: `exams_select` compares
// the columns against a paper's own labels, so a correction that stores
// "computer science" beside a paper's "Computer Science" is a change that fixes
// nothing — the student stays locked out of the paper the admin was trying to
// unlock.
//
// So this function refuses anything the catalogue does not name, the same way the
// dropdowns in the app do (they cannot offer a free-text value at all).
//
// THIS FILE IS A MIRROR. The app's copy is
// `mobile/lib/core/utils/academic_catalog.dart`, and the two are pinned together
// by `mobile/test/schema_contract_test.dart` ("the function and the app agree on
// the catalogue"): a faculty added on one side and not the other fails the
// Flutter suite instead of silently refusing a valid label in production. Edit
// both, in the same order.

/** The levels a student or a paper can be labelled with, in dropdown order. */
export const LEVELS: readonly string[] = [
  "100",
  "200",
  "300",
  "400",
  "500",
  "600",
];

/** Faculty → its departments, in the order the app's dropdowns offer them. */
export const FACULTIES: Readonly<Record<string, readonly string[]>> = {
  "Science": [
    "Computer Science",
    "Mathematics",
    "Physics",
    "Chemistry",
    "Biology",
    "Statistics",
  ],
  "Engineering": [
    "Computer Engineering",
    "Electrical and Electronics Engineering",
    "Mechanical Engineering",
    "Civil Engineering",
  ],
  "Social Sciences": [
    "Economics",
    "Mass Communication",
    "Political Science",
    "Sociology",
    "Psychology",
  ],
  "Management Sciences": [
    "Accounting",
    "Business Administration",
    "Banking and Finance",
    "Marketing",
  ],
  "Arts": [
    "English",
    "History and International Studies",
    "Linguistics",
    "Philosophy",
    "Theatre Arts",
  ],
  "Education": [
    "Educational Foundations",
    "Science Education",
    "Guidance and Counselling",
  ],
};

/** The faculties, for an error message that lists them. */
export const FACULTY_NAMES: readonly string[] = Object.keys(FACULTIES);

/** Every department once, in faculty order. */
export function allDepartments(): string[] {
  const seen = new Set<string>();
  const all: string[] = [];
  for (const departments of Object.values(FACULTIES)) {
    for (const department of departments) {
      const key = department.toLowerCase();
      if (!seen.has(key)) {
        seen.add(key);
        all.push(department);
      }
    }
  }
  return all;
}

/** Trims [raw] and reads a blank as *not stated* (`null`). */
export function clean(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const value = raw.trim();
  return value.length === 0 ? null : value;
}

/**
 * The catalogue's spelling of [raw] as a faculty, or `null` when it names none.
 *
 * Case-insensitive on purpose: `exams_select` compares these columns with
 * `lower(a) = lower(b)`, so "science" and "Science" already reach the same
 * papers — the difference is only in what a human reads on the roster, and the
 * catalogue's spelling is what the console shows.
 */
export function canonicalFaculty(raw: unknown): string | null {
  const value = clean(raw)?.toLowerCase();
  if (value === null || value === undefined) return null;
  for (const faculty of FACULTY_NAMES) {
    if (faculty.toLowerCase() === value) return faculty;
  }
  return null;
}

/**
 * The catalogue's spelling of [raw] as a department, or `null` when it names
 * none.
 *
 * [faculty] narrows the search to that faculty's departments when it names one
 * of them; an unknown or absent faculty leaves the whole catalogue open, which is
 * the same rule `AcademicCatalog.departmentsFor` applies to the app's dropdowns.
 * A department that exists under a *different* faculty answers `null` here and is
 * explained by the caller with [facultyOf], since "Accounting sits under
 * Management Sciences, not Science" is more use than "not a department".
 */
export function canonicalDepartment(
  raw: unknown,
  faculty?: unknown,
): string | null {
  const value = clean(raw)?.toLowerCase();
  if (value === null || value === undefined) return null;
  const scope = canonicalFaculty(faculty);
  const pool = scope === null ? allDepartments() : FACULTIES[scope];
  for (const department of pool) {
    if (department.toLowerCase() === value) return department;
  }
  return null;
}

/** The faculty a catalogue department belongs to, or `null` when it is not one. */
export function facultyOf(department: unknown): string | null {
  const value = clean(department)?.toLowerCase();
  if (value === null || value === undefined) return null;
  for (const [faculty, departments] of Object.entries(FACULTIES)) {
    for (const candidate of departments) {
      if (candidate.toLowerCase() === value) return faculty;
    }
  }
  return null;
}

/**
 * The catalogue's spelling of an imported level, or `null` when the value names
 * no level at all.
 *
 * The same reading the app applies to a spreadsheet ("300 Level", "300L",
 * "LEVEL 300" → "300"), because `level` is compared with plain equality: storing
 * "300 level" would hide every 300-level paper from that student. A four-digit
 * typo ("3000") is refused rather than read as "300" — the digits that name the
 * cohort have to be the only digits in the cell.
 */
export function normaliseLevel(raw: unknown): string | null {
  const value = clean(raw)?.toLowerCase();
  if (value === null || value === undefined) return null;

  const digits = [...value.matchAll(/\d+/g)];
  if (digits.length !== 1 || digits[0][0].length !== 3) return null;

  const level = digits[0][0];
  if (!LEVELS.includes(level)) return null;

  // Whatever else the cell says has to be the word for the label — "300 Level",
  // "300L", "LEVEL 300" — and nothing more ("300 (repeat)").
  const start = digits[0].index ?? 0;
  const rest = `${value.slice(0, start)}${value.slice(start + 3)}`.replace(
    /[^a-z]/g,
    "",
  );
  return rest === "" || rest === "l" || rest === "lvl" || rest === "level"
    ? level
    : null;
}

