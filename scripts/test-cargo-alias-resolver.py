from __future__ import annotations

import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


sys.dont_write_bytecode = True
_SOURCE = Path(__file__).with_name("cargo-alias-resolver.py")
_SPEC = importlib.util.spec_from_file_location("cargo_alias_resolver", _SOURCE)
assert _SPEC is not None and _SPEC.loader is not None
resolver = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(resolver)


class AliasFixtures(unittest.TestCase):
    def setUp(self) -> None:
        temp_parent = Path("C:/Temp") if os.name == "nt" else Path(tempfile.gettempdir())
        self.fixture = tempfile.TemporaryDirectory(prefix="codex-cargo-alias-resolver-", dir=temp_parent)
        self.root = Path(self.fixture.name).resolve()
        self.assertEqual(self.root.parent, temp_parent.resolve())
        self.assertTrue(self.root.name.startswith("codex-cargo-alias-resolver-"))
        self.addCleanup(self.fixture.cleanup)
        self.project = self.root / "projects" / "workspace" / "member"
        self.project.mkdir(parents=True)
        self.home = self.root / "home" / ".cargo"
        self.home.mkdir(parents=True)
        self.environment = {"CARGO_HOME": str(self.home)}

    def write(self, relative: str | Path, contents: str) -> Path:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents, encoding="utf-8")
        return path

    def aliases(self, directory: Path, values: dict[str, object], *, legacy: bool = False) -> Path:
        filename = "config" if legacy else "config.toml"
        contents = "[alias]\n" + "".join(json.dumps(key) + " = " + json.dumps(value) + "\n" for key, value in values.items())
        return self.write(directory / filename, contents)

    def resolve(self, command: str = "ci", arguments: tuple[str, ...] = (), **kwargs: object) -> list[str] | None:
        return resolver.resolve_alias(
            command,
            arguments,
            cwd=kwargs.get("cwd", self.project),
            environment=kwargs.get("environment", self.environment),
            search_stop=self.root,
        )

    def test_unknown_command_and_builtin_fallbacks(self) -> None:
        self.assertIsNone(self.resolve("custom-plugin"))
        for name, target in {"b": "build", "c": "check", "d": "doc", "r": "run", "t": "test", "rm": "remove"}.items():
            with self.subTest(name=name):
                self.assertEqual(self.resolve(name), [target])

    def test_array_preserves_windows_paths_spaces_quotes_and_empty_args(self) -> None:
        expected = ["check", "--target-dir", "C:\\Build Cache\\target\\", "", 'quote"inside', "кириллица", "-j8"]
        self.aliases(self.project / ".cargo", {"ci": expected})
        actual = self.resolve()
        self.assertEqual(actual, expected)
        payload = resolver.encode_resolution(actual)
        self.assertEqual(payload[:2], b"A\n")
        self.assertEqual(payload[2:].split(b"\0")[:-1], [argument.encode("utf-8") for argument in expected])
        self.assertEqual(payload[-1:], b"\0")

    def test_string_alias_uses_native_whitespace_not_shell_quoting(self) -> None:
        self.aliases(self.project / ".cargo", {"ci": r'check --target-dir "C:\Build Cache" -j8'})
        self.assertEqual(self.resolve(), ["check", "--target-dir", '"C:\\Build', 'Cache"', "-j8"])

    def test_rust_unicode_whitespace_keeps_python_extra_control_separators(self) -> None:
        self.aliases(self.project / ".cargo", {"ci": "check\u0085--quiet\u001cvalue\u3000-j8"})
        self.assertEqual(self.resolve(), ["check", "--quiet\u001cvalue", "-j8"])

    def test_bang_prefix_remains_literal_without_executing_a_shell(self) -> None:
        self.aliases(self.project / ".cargo", {"ci": "!echo hello"})
        self.assertEqual(self.resolve(), ["!echo", "hello"])

    def test_deeper_string_config_overrides_cargo_home_and_ancestors(self) -> None:
        self.aliases(self.home, {"ci": "build --release"})
        self.aliases(self.root / ".cargo", {"ci": "check --workspace"})
        self.aliases(self.project.parent / ".cargo", {"ci": "test --lib"})
        self.aliases(self.project / ".cargo", {"ci": "check --all-targets"})
        self.assertEqual(self.resolve(), ["check", "--all-targets"])

    def test_array_layers_append_low_to_high_then_environment(self) -> None:
        self.aliases(self.home, {"ci": ["check"]})
        self.aliases(self.root / ".cargo", {"ci": ["--workspace"]})
        self.aliases(self.project.parent / ".cargo", {"ci": ["--release"]})
        self.aliases(self.project / ".cargo", {"ci": ["--target-dir", "C:\\Target With Spaces"]})
        self.environment["CARGO_ALIAS_CI"] = "--quiet -j8"
        self.assertEqual(self.resolve(), ["check", "--workspace", "--release", "--target-dir", "C:\\Target With Spaces", "--quiet", "-j8"])

    def test_environment_overrides_string_alias(self) -> None:
        self.aliases(self.project / ".cargo", {"ci": "build --release"})
        self.environment["CARGO_ALIAS_CI"] = "test --lib -j8"
        self.assertEqual(self.resolve(), ["test", "--lib", "-j8"])

    def test_environment_only_alias_normalizes_hyphens_and_case(self) -> None:
        self.environment["CARGO_ALIAS_LONG_NAME"] = "clippy --all-targets"
        self.assertEqual(self.resolve("long-name"), ["clippy", "--all-targets"])

    def test_pre_expansion_advanced_env_does_not_parse_toml_array(self) -> None:
        self.environment["CARGO_ALIAS_CI"] = '["check", "-j8"]'
        self.assertEqual(self.resolve(arguments=("-Zadvanced-env",)), ['["check",', '"-j8"]'])

    def test_user_alias_can_override_builtin_shortcut(self) -> None:
        self.aliases(self.project / ".cargo", {"b": "check --workspace"})
        self.assertEqual(self.resolve("b"), ["check", "--workspace"])

    def test_legacy_config_takes_precedence_over_config_toml(self) -> None:
        self.aliases(self.project / ".cargo", {"ci": "build"})
        self.aliases(self.project / ".cargo", {"ci": "test"}, legacy=True)
        self.assertEqual(self.resolve(), ["test"])

    def test_cargo_home_already_in_ancestor_chain_is_not_loaded_twice(self) -> None:
        ancestor_home = self.project.parent / ".cargo"
        self.aliases(ancestor_home, {"ci": ["check", "--workspace"]})
        self.environment["CARGO_HOME"] = str(ancestor_home)
        self.assertEqual(self.resolve(), ["check", "--workspace"])

    def test_relative_cargo_home_is_resolved_against_effective_cwd(self) -> None:
        self.aliases(self.project / "cargo-home", {"ci": "test"})
        self.environment["CARGO_HOME"] = "cargo-home"
        self.assertEqual(self.resolve(), ["test"])

    def test_configs_inside_other_workspace_members_are_not_read(self) -> None:
        other = self.project.parent / "another-member"
        self.aliases(other / ".cargo", {"ci": "build -j99"})
        self.assertIsNone(self.resolve())

    def test_cli_alias_overrides_and_color_do_not_change_native_selection(self) -> None:
        self.aliases(self.project / ".cargo", {"ci": "check -j8"})
        extra = self.aliases(self.root / "extra-config", {"ci": "build -j99"})
        arguments = ("+1.97.1", "--color", "always", "--config", 'alias.ci="test"', "--config=" + str(extra))
        self.assertEqual(self.resolve(arguments=arguments), ["check", "-j8"])

    def test_cli_config_only_alias_is_not_visible_before_native_configure(self) -> None:
        self.assertIsNone(self.resolve(arguments=("--config", 'alias.ci="build -j8"')))

    def test_cli_config_argument_is_not_interpreted_as_an_original_cwd(self) -> None:
        self.aliases(self.project / ".cargo", {"ci": "check"})
        self.assertEqual(self.resolve(arguments=("--config", "-Cmissing")), ["check"])

    def test_original_cwd_option_applies_before_config_lookup(self) -> None:
        changed = self.project / "target project"
        self.aliases(changed / ".cargo", {"ci": "test --lib"})
        self.aliases(self.project / ".cargo", {"ci": "check"})
        for arguments in (("-C", "target project"), ("-Ctarget project",), ("-C=target project",), ("-qCtarget project",)):
            with self.subTest(arguments=arguments):
                self.assertEqual(self.resolve(arguments=arguments), ["test", "--lib"])

    def test_global_value_options_do_not_reinterpret_their_payload(self) -> None:
        self.aliases(self.project / ".cargo", {"ci": "check"})
        self.assertEqual(self.resolve(arguments=("-Z", "-Cmissing", "--color=always")), ["check"])

    def test_missing_empty_duplicate_or_invalid_cwd_options_fail_closed(self) -> None:
        for arguments in (("-C",), ("-C=",), ("-C", "missing"), ("-C", ".", "-C", "."), ("--color",)):
            with self.subTest(arguments=arguments):
                with self.assertRaises(resolver.AliasError):
                    self.resolve(arguments=arguments)

    def test_recursive_includes_use_left_to_right_then_own_values(self) -> None:
        self.write("includes/low.toml", '[alias]\nci = "build"\n')
        self.write("includes/high.toml", 'include = ["nested.toml"]\n[alias]\nci = "test"\n')
        self.write("includes/nested.toml", '[alias]\nci = "doc"\n')
        self.write(self.project / ".cargo/config.toml", 'include = ["../../../..\\includes/low.toml", "../../../..\\includes/high.toml"]\n[alias]\nci = "check --workspace"\n'.replace("\\", "/"))
        self.assertEqual(self.resolve(), ["check", "--workspace"])

    def test_include_arrays_preserve_order_and_exact_tokens(self) -> None:
        config_dir = self.project / ".cargo"
        self.write(config_dir / "a.toml", '[alias]\nci = ["check", ""]\n')
        self.write(config_dir / "nested.toml", '[alias]\nci = ["--release"]\n')
        self.write(config_dir / "b.toml", 'include = ["nested.toml"]\n[alias]\nci = ' + json.dumps(["--target-dir", "C:\\Build Cache"]) + '\n')
        self.write(config_dir / "config.toml", 'include = ["a.toml", "b.toml"]\n[alias]\nci = ["-j8"]\n')
        self.assertEqual(self.resolve(), ["check", "", "--release", "--target-dir", "C:\\Build Cache", "-j8"])

    def test_optional_missing_include_and_required_table_include(self) -> None:
        config_dir = self.project / ".cargo"
        self.write(config_dir / "required.toml", '[alias]\nci = "check"\n')
        self.write(config_dir / "config.toml", 'include = [{path="absent.toml", optional=true}, {path="required.toml"}]\n')
        self.assertEqual(self.resolve(), ["check"])

    def test_include_cycles_repeated_paths_and_missing_required_files_fail(self) -> None:
        config_dir = self.project / ".cargo"
        self.write(config_dir / "other.toml", 'include = ["config.toml"]\n')
        for includes in ('["other.toml"]', '["missing.toml"]', '["repeat.toml", "repeat.toml"]'):
            with self.subTest(includes=includes):
                self.write(config_dir / "repeat.toml", '[alias]\nci="check"\n')
                self.write(config_dir / "config.toml", "include = " + includes + "\n")
                with self.assertRaises(resolver.AliasError):
                    self.resolve()

    def test_invalid_include_formats_fail_closed(self) -> None:
        for includes in ('"other.toml"', '["other.txt"]', '["*.toml"]', '["{other}.toml"]', '[7]', '[{optional=true}]', '[{path="x.toml", optional="true"}]'):
            with self.subTest(includes=includes):
                self.write(self.project / ".cargo/config.toml", "include = " + includes + "\n")
                with self.assertRaises(resolver.AliasError):
                    self.resolve()

    def test_mixed_scalar_and_array_layers_fail_instead_of_reconstructing_argv(self) -> None:
        self.aliases(self.home, {"ci": ["build"]})
        self.aliases(self.project / ".cargo", {"ci": "check"})
        with self.assertRaises(resolver.AliasError):
            self.resolve()

    def test_overridden_primitive_type_matches_cargo_merge(self) -> None:
        self.aliases(self.home, {"ci": 42})
        self.aliases(self.project / ".cargo", {"ci": "check"})
        self.assertEqual(self.resolve(), ["check"])

    def test_invalid_alias_argument_types_empty_aliases_and_nul_fail(self) -> None:
        for value in (42, True, ["build", 2], ["build", True], [], "", "   ", ["check", "a\0b"], "check\0arg"):
            with self.subTest(value=value):
                self.aliases(self.project / ".cargo", {"ci": value})
                with self.assertRaises(resolver.AliasError):
                    self.resolve()
        with self.assertRaises(resolver.AliasError):
            self.resolve("a\0b")

    def test_empty_array_can_receive_environment_arguments(self) -> None:
        self.aliases(self.project / ".cargo", {"ci": []})
        self.environment["CARGO_ALIAS_CI"] = "check"
        self.assertEqual(self.resolve(), ["check"])

    def test_original_cwd_resolution_restores_the_calling_process_directory(self) -> None:
        changed = self.project / "target project"
        self.aliases(changed / ".cargo", {"ci": "check"})
        original = Path.cwd()
        self.assertEqual(self.resolve(arguments=("-C", "target project")), ["check"])
        self.assertEqual(Path.cwd(), original)

    def test_unknown_command_protocol_is_exact_lf(self) -> None:
        self.assertEqual(resolver.encode_resolution(self.resolve("unknown-plugin")), b"N\n")

    def test_dotted_alias_names_follow_native_config_key_lookup(self) -> None:
        self.write(self.project / ".cargo/config.toml", '[alias.foo]\nbar = "check"\n')
        self.assertEqual(self.resolve("foo.bar"), ["check"])
        self.aliases(self.project / ".cargo", {"foo.bar": "build"})
        self.assertIsNone(self.resolve("foo.bar"))

    def test_toml_error_does_not_echo_unrelated_config_content(self) -> None:
        sensitive = "private-config-fixture-value"
        self.write(self.project / ".cargo/config.toml", 'unrelated-secret = "' + sensitive + '"\n[alias]\nci = [\n')
        with self.assertRaises(resolver.AliasError) as caught:
            self.resolve()
        self.assertNotIn(sensitive, str(caught.exception))

    def test_main_writes_binary_protocol_and_sanitizes_errors(self) -> None:
        stdout = SimpleNamespace(buffer=io.BytesIO())
        stderr = io.StringIO()
        with patch.object(resolver, "resolve_alias", return_value=["check", "", "кириллица"]), patch.object(sys, "stdout", stdout), patch.object(sys, "stderr", stderr):
            self.assertEqual(resolver.main(["ci"]), 0)
        self.assertEqual(stdout.buffer.getvalue(), b"A\ncheck\0\0" + "кириллица".encode("utf-8") + b"\0")
        self.assertEqual(stderr.getvalue(), "")
        stdout.buffer = io.BytesIO()
        with patch.object(resolver, "resolve_alias", side_effect=OSError("private-config-fixture-value")), patch.object(sys, "stdout", stdout), patch.object(sys, "stderr", stderr):
            self.assertEqual(resolver.main(["ci"]), 2)
        self.assertEqual(stdout.buffer.getvalue(), b"")
        self.assertNotIn("private-config-fixture-value", stderr.getvalue())

    def test_real_isolated_python_cli_preserves_lf_and_array_payload(self) -> None:
        name = "codex-fixture-lossless-array-20261124"
        expected = ["check", "--target-dir", "C:\\Build Cache\\", "", "-j8"]
        self.aliases(self.project / ".cargo", {name: expected})
        environment = dict(os.environ)
        environment["CARGO_HOME"] = str(self.home)
        environment.pop("CARGO_ALIAS_" + name.replace("-", "_").upper(), None)
        result = subprocess.run(
            [sys.executable, "-I", "-B", "-X", "utf8", str(_SOURCE), name, "--color", "always"],
            cwd=self.project,
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            creationflags=subprocess.BELOW_NORMAL_PRIORITY_CLASS if os.name == "nt" else 0,
        )
        self.assertEqual(result.returncode, 0, result.stderr.decode("utf-8"))
        self.assertEqual(result.stdout, resolver.encode_resolution(expected))
        self.assertNotIn(b"\r\n", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
