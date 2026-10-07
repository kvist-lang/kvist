"""Source-reference regressions against the real CLI (no compiler execution)."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

CLI = str(Path(os.environ.get('KVIST_REFERENCE_CLI', './kvist')).resolve())


class ReferencesTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='kvist-references-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        (self.root / '.git').write_text('')
        self.main = self.write('main.kvist', '''(package main)
(import service "lib")
(def answer 1)
(defn run [answer: int]
  (println answer)
  (let [answer (+ answer 1)]
    (println answer))
  (println answer))
(defn main []
  (println answer service.answer service/answer "answer")
  ;; answer service.answer
  #_(println answer)
  '(answer service.answer)
  (println (+ answer answer)))
''')
        self.lib = self.write('lib/lib.kvist', '''(package lib)
(def answer 42)
(defn value [] answer)
''')
        self.write('other/main.kvist', '''(package main)
(import renamed "../lib")
(import "../lib" :refer [answer] :as service)
(defn other [] (println renamed.answer answer))
''')
        self.write('unrelated/unrelated.kvist', '''(package unrelated)
(def answer 0)
(defn main [] answer)
''')
        self.write('.worktrees/ignored/main.kvist', '(package main) (println answer)')
        self.write('build/main.kvist', '(package main) (println answer)')
        self.write('broken.kvist', '(package main) (defn incomplete [')

    def write(self, name, source):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(source)
        return path

    def query(self, identifier, *args, file=None, command='references'):
        result = subprocess.run([CLI, command, str(file or self.main), identifier, *args],
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return [tuple(row.split('\t', 2)) for row in result.stdout.splitlines()]

    def locations(self, rows):
        return [row[0].removeprefix(str(self.root) + '/') for row in rows]

    def test_globals_exclude_shadowed_bindings_and_noncode(self):
        rows = self.query('answer')
        self.assertEqual(self.locations(rows), ['main.kvist:10:12', 'main.kvist:14:15', 'main.kvist:14:22'])
        self.assertEqual([r[1] for r in rows], ['answer'] * 3)

    def test_local_parameter_and_nested_binding_are_distinct(self):
        rows = self.query('answer', '--line', '4', '--column', '12')
        self.assertEqual(self.locations(rows), ['main.kvist:5:12', 'main.kvist:6:19', 'main.kvist:8:12'])
        rows = self.query('answer', '--line', '6', '--column', '10')
        self.assertEqual(self.locations(rows), ['main.kvist:7:14'])
        self.assertEqual(rows, self.query('answer', '--line', '7', '--column', '18'))

    def test_import_aliases_and_referred_names_resolve_to_one_symbol(self):
        rows = self.query('service.answer')
        self.assertEqual(self.locations(rows), ['lib/lib.kvist:3:16', 'main.kvist:10:19',
                                                'main.kvist:10:34', 'other/main.kvist:4:25',
                                                'other/main.kvist:4:40'])
        self.assertEqual(rows, self.query('service/answer'))
        self.assertEqual(rows, self.query('answer', file=self.lib))
        self.assertEqual(rows, self.query('service.answer', '--line', '10', '--column', '21'))

    def test_root_and_usages_alias(self):
        self.assertEqual(self.query('answer'), self.query('answer', command='usages'))
        rows = self.query('service.answer', '--root', str(self.root / 'lib'))
        self.assertEqual(self.locations(rows), ['lib/lib.kvist:3:16', 'main.kvist:10:19', 'main.kvist:10:34'])

    def test_overlay_keeps_real_source_paths_and_does_not_save(self):
        overlay = self.write('overlay.tmp', self.main.read_text() + '(println answer)\n')
        rows = self.query('answer', '--source', str(overlay))
        self.assertEqual(self.locations(rows)[-1], 'main.kvist:15:10')
        self.assertNotIn('overlay.tmp', str(rows))
        self.assertEqual(len(self.query('answer')), 3)

    def test_no_matches_is_success_and_invalid_options_are_errors(self):
        self.assertEqual(self.query('never-used'), [])
        for args in [('--line', '4'), ('--column', '-1'), ('--root',), ('--unknown', 'x'),
                     ('--line', '1', '--column', '1')]:
            result = subprocess.run([CLI, 'references', str(self.main), 'answer', *args],
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0, args)
            self.assertTrue(result.stderr)

    def test_conditional_binding_initializer_and_else_scope(self):
        self.main.write_text('''(package main)
(def answer 1)
(defn main []
  (if-let [[answer ok] (lookup answer)]
    (println answer)
    (println answer)))
''')
        self.assertEqual(self.locations(self.query('answer')), ['main.kvist:4:32'])
        self.assertEqual(self.locations(self.query('answer', '--line', '4', '--column', '13')),
                         ['main.kvist:5:14', 'main.kvist:6:14'])

    def test_destructuring_and_loop_scopes(self):
        self.main.write_text('''(package main)
(def answer 1)
(defn main []
  (let [[answer other] (values answer)] (println answer other))
  (for [answer (values answer)] (println answer))
  (println answer))
''')
        self.assertEqual(self.locations(self.query('answer')), ['main.kvist:4:32', 'main.kvist:5:24', 'main.kvist:6:12'])
        self.assertEqual(self.locations(self.query('answer', '--line', '4', '--column', '10')),
                         ['main.kvist:4:50'])
        self.assertEqual(self.locations(self.query('answer', '--line', '5', '--column', '9')),
                         ['main.kvist:5:42'])

    def test_qualified_query_at_point_accepts_emacs_slash_normalization(self):
        self.assertEqual(self.query('service.answer'),
                         self.query('service/answer', '--line', '10', '--column', '19'))

    def test_type_names_in_compact_annotations(self):
        self.main.write_text('''(package main)
(defstruct User [name: string])
(defstruct Group [users: []User])
(defn consume [one: ^User many: []User] -> User one)
(def user-map: map[string]User (make map[string]User))
''')
        self.assertEqual(self.locations(self.query('User')), ['main.kvist:3:28',
                         'main.kvist:4:22', 'main.kvist:4:35', 'main.kvist:4:44',
                         'main.kvist:5:27', 'main.kvist:5:49'])

    def test_macro_parameters_and_executable_unquotes(self):
        self.main.write_text('''(package main)
(def answer 1)
(defmacro wrap [answer] `(println ~answer))
(defn main [] (wrap answer))
''')
        self.assertEqual(self.locations(self.query('answer')), ['main.kvist:4:21'])
        self.assertEqual(self.locations(self.query('answer', '--line', '3', '--column', '17')),
                         ['main.kvist:3:36'])

    def test_different_package_next_to_anchor_is_independent(self):
        self.write('standalone.kvist', '(package standalone) (def answer 2) (println answer)')
        self.assertEqual(len(self.query('answer')), 3)

    def test_local_receiver_shadows_import_alias(self):
        self.main.write_text('''(package main)
(import service "lib")
(defn run [service: Service] (println service.answer))
(defn main [] (println service.answer))
''')
        self.assertEqual(self.locations(self.query('service.answer')),
                         ['lib/lib.kvist:3:16', 'main.kvist:4:24',
                          'other/main.kvist:4:25', 'other/main.kvist:4:40'])
        self.assertEqual(self.locations(self.query('service', '--line', '3', '--column', '12')),
                         ['main.kvist:3:39'])

    def test_imports_are_available_in_sibling_package_files(self):
        self.write('helpers.kvist', '(package main) (defn helper [] service.answer)')
        self.assertEqual(self.locations(self.query('service.answer'))[0], 'helpers.kvist:1:32')

    def test_deftransform_declaration_is_not_a_usage(self):
        self.main.write_text('''(package main)
(deftransform positives (filter positive?))
(defn main [] (into []int positives values))
''')
        self.assertEqual(self.locations(self.query('positives')), ['main.kvist:3:27'])

    def test_map_destructuring_defaults_are_uses(self):
        self.main.write_text('''(package main)
(def fallback 10)
(defn main []
  (let [{:keys [value] :or {value fallback}} input] (println value)))
''')
        self.assertEqual(self.locations(self.query('fallback')), ['main.kvist:4:35'])
        self.assertEqual(self.locations(self.query('value', '--line', '4', '--column', '17')),
                         ['main.kvist:4:62'])

    def test_postfix_field_names_are_not_global_references(self):
        self.main.write_text('''(package main)
(def answer 1)
(defn main [] (println (user).answer answer))
''')
        self.assertEqual(self.locations(self.query('answer')), ['main.kvist:3:38'])


if __name__ == '__main__':
    unittest.main()
