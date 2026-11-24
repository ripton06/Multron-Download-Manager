from __future__ import annotations

import os
from pathlib import Path
import re
import sys
import tomllib
from collections.abc import Mapping, Sequence


class AliasError(RuntimeError):
    pass


_MISSING = object()
_BUILTINS = {"b": "build", "c": "check", "d": "doc", "r": "run", "t": "test", "rm": "remove"}
_RUST_WHITESPACE = re.compile(
    r"[\u0009-\u000d\u0020\u0085\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000]+"
)
_MAX_INCLUDE_DEPTH = 128


def _split_whitespace(value: str) -> list[str]:
    return [word for word in _RUST_WHITESPACE.split(value) if word]


def _absolute(path: str | Path, cwd: Path) -> Path:
    return Path(os.path.abspath(cwd / path))


def _global_cwd(arguments: Sequence[str], cwd: Path) -> Path:
    directory: str | None = None
    index = 0
    while index < len(arguments):
        argument = arguments[index]
        if "\0" in argument:
            raise AliasError("a global argument contains NUL")
        if argument.startswith("+") or argument == "--":
            index += 1
            continue
        if argument in ("--config", "--color", "--explain"):
            if index + 1 == len(arguments):
                raise AliasError("a global option is missing its argument")
            index += 2
            continue
        if argument.startswith("--"):
            index += 1
            continue
        if not argument.startswith("-") or argument == "-":
            raise AliasError("unexpected non-option before the Cargo command")

        for offset in range(1, len(argument)):
            flag = argument[offset]
            if flag in "qvhV":
                continue
            if flag not in "CZ":
                raise AliasError("unsupported global short option")
            value = argument[offset + 1 :]
            if value.startswith("="):
                value = value[1:]
            elif not value:
                if index + 1 == len(arguments):
                    raise AliasError("a global option is missing its argument")
                index += 1
                value = arguments[index]
            if "\0" in value:
                raise AliasError("a global argument contains NUL")
            if flag == "C":
                if directory is not None:
                    raise AliasError("multiple -C arguments cannot be resolved faithfully")
                if not value:
                    raise AliasError("the -C directory is empty")
                directory = value
            break
        index += 1

    if directory is None:
        return cwd
    effective = _absolute(directory, cwd)
    if not effective.is_dir():
        raise AliasError("the -C directory is unavailable")
    original = Path.cwd()
    try:
        os.chdir(effective)
        return Path.cwd()
    except OSError:
        raise AliasError("the -C directory is unavailable") from None
    finally:
        os.chdir(original)


def _cargo_home(cwd: Path, environment: Mapping[str, str]) -> Path:
    configured = environment.get("CARGO_HOME")
    if configured:
        return _absolute(configured, cwd)
    if os.name == "nt":
        profile = environment.get("USERPROFILE")
        if not profile:
            drive = environment.get("HOMEDRIVE", "")
            home_path = environment.get("HOMEPATH", "")
            profile = drive + home_path if drive and home_path else None
    else:
        profile = environment.get("HOME")
    if profile:
        return _absolute(Path(profile) / ".cargo", cwd)
    try:
        return Path.home() / ".cargo"
    except (OSError, RuntimeError):
        raise AliasError("the Cargo home directory is unavailable") from None


def _config_file(directory: Path) -> Path | None:
    legacy = directory / "config"
    modern = directory / "config.toml"
    if legacy.exists():
        return legacy
    if modern.exists():
        return modern
    return None


def _configuration_paths(cwd: Path, home: Path, search_stop: Path | None = None) -> list[Path]:
    paths: list[Path] = []
    config_roots: set[Path] = set()
    for ancestor in (cwd, *cwd.parents):
        config_root = ancestor / ".cargo"
        config_roots.add(config_root.resolve())
        path = _config_file(config_root)
        if path is not None:
            paths.append(path)
        if search_stop is not None and ancestor == search_stop:
            break
    if home.resolve() not in config_roots:
        path = _config_file(home)
        if path is not None:
            paths.append(path)
    paths.reverse()
    return paths


def _selected_alias(document: dict[str, object], command: str) -> object:
    selected: object = document
    for part in ("alias", *command.split(".")):
        if not isinstance(selected, dict):
            raise AliasError("the alias configuration has an incompatible table type")
        selected = selected.get(part, _MISSING)
        if selected is _MISSING:
            return _MISSING
    return selected


def _merge_alias(lower: object, higher: object) -> object:
    if lower is _MISSING:
        return higher
    if higher is _MISSING:
        return lower
    if isinstance(lower, list) and isinstance(higher, list):
        return lower + higher
    if isinstance(lower, (list, dict)) or isinstance(higher, (list, dict)):
        raise AliasError("alias layers use incompatible configuration types")
    return higher


def _include_paths(document: dict[str, object], directory: Path) -> list[Path]:
    entries = document.get("include", [])
    if not isinstance(entries, list):
        raise AliasError("Cargo include must be an array")
    paths: list[Path] = []
    for entry in entries:
        optional = False
        if isinstance(entry, str):
            value = entry
        elif isinstance(entry, dict):
            value = entry.get("path")
            optional = entry.get("optional", False)
            if not isinstance(value, str) or not isinstance(optional, bool):
                raise AliasError("Cargo include table has an invalid path or optional flag")
        else:
            raise AliasError("Cargo include entries must be paths or tables")
        if "\0" in value or Path(value).suffix != ".toml" or any(char in value for char in "*?[]{}"):
            raise AliasError("Cargo include path uses an unsupported format")
        path = _absolute(value, directory)
        if optional and not path.exists():
            continue
        paths.append(path)
    return paths


def _load_alias(path: Path, command: str, seen: set[Path], depth: int = 0) -> object:
    path = _absolute(path, Path.cwd())
    if path in seen or depth >= _MAX_INCLUDE_DEPTH:
        raise AliasError("Cargo configuration includes repeat or exceed the depth limit")
    seen.add(path)
    try:
        with path.open("rb") as source:
            document = tomllib.load(source)
    except tomllib.TOMLDecodeError:
        raise AliasError("a Cargo configuration file contains invalid TOML") from None
    except (OSError, UnicodeError):
        raise AliasError("a Cargo configuration file could not be read") from None
    selected = _MISSING
    for included in _include_paths(document, path.parent):
        selected = _merge_alias(selected, _load_alias(included, command, seen, depth + 1))
    return _merge_alias(selected, _selected_alias(document, command))


def resolve_alias(
    command: str,
    global_arguments: Sequence[str] = (),
    *,
    cwd: Path | None = None,
    environment: Mapping[str, str] | None = None,
    search_stop: Path | None = None,
) -> list[str] | None:
    if not command or "\0" in command:
        raise AliasError("the alias name is empty or contains NUL")
    current = Path(os.path.abspath(cwd if cwd is not None else Path.cwd()))
    environment = os.environ if environment is None else environment
    current = _global_cwd(global_arguments, current)
    home = _cargo_home(current, environment)
    selected: object = _MISSING
    for config in _configuration_paths(current, home, search_stop):
        selected = _merge_alias(selected, _load_alias(config, command, set()))

    env_key = "CARGO_ALIAS_" + command.replace(".", "_").replace("-", "_").upper()
    env_value = environment.get(env_key)
    if env_value is not None:
        if "\0" in env_value:
            raise AliasError("an environment alias contains NUL")
        if isinstance(selected, list):
            selected = selected + _split_whitespace(env_value)
        elif selected is _MISSING or isinstance(selected, str):
            selected = env_value
        else:
            raise AliasError("the environment cannot override this alias configuration type")

    if selected is _MISSING:
        builtin = _BUILTINS.get(command)
        return [builtin] if builtin is not None else None
    if isinstance(selected, str):
        arguments = _split_whitespace(selected)
    elif isinstance(selected, list) and all(isinstance(item, str) for item in selected):
        arguments = selected.copy()
    else:
        raise AliasError("the alias must be a string or an array of strings")
    if not arguments:
        raise AliasError("the alias does not contain a command")
    if any("\0" in argument for argument in arguments):
        raise AliasError("an alias argument contains NUL")
    return arguments


def encode_resolution(arguments: list[str] | None) -> bytes:
    if arguments is None:
        return b"N\n"
    if not arguments or any("\0" in argument for argument in arguments):
        raise AliasError("the alias response is empty or contains NUL")
    return b"A\n" + b"\0".join(argument.encode("utf-8") for argument in arguments) + b"\0"


def main(arguments: Sequence[str] | None = None) -> int:
    arguments = list(sys.argv[1:] if arguments is None else arguments)
    try:
        if not arguments:
            raise AliasError("an alias name is required")
        payload = encode_resolution(resolve_alias(arguments[0], arguments[1:]))
        sys.stdout.buffer.write(payload)
        return 0
    except (AliasError, OSError, UnicodeError, RuntimeError) as error:
        diagnostic = str(error) if isinstance(error, AliasError) else "alias configuration could not be resolved"
        sys.stderr.write("cargo-alias-resolver: " + diagnostic + "\n")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
