import QtQuick
import Quickshell
import "asserts.js" as A

// Unit: the input-guard validators that stop injection through LLAMA_EXTRA_ARGS
// (shell-expanded into ExecStart) and unsafe model-preset paths, plus truncate.
Item {
  id: root
  Component.onCompleted: {
    var s = A.service("@SERVICE_QML_PATH@", root, "llama.cpp")

    A.check("extraargs/empty", s.validateExtraArgs(""), true)
    A.check("extraargs/simple", s.validateExtraArgs("--temp 0.7 --threads 8"), true)
    A.check("extraargs/dotslash", s.validateExtraArgs("./bin/x"), true)
    A.check("extraargs/semicolon", s.validateExtraArgs("a;b"), false)
    A.check("extraargs/tilde", s.validateExtraArgs("~/x"), false)
    A.check("extraargs/subshell", s.validateExtraArgs("$(rm -rf /)"), false)
    A.check("extraargs/backtick", s.validateExtraArgs("`x`"), false)

    A.check("preset/empty", s.isValidPresetPath(""), true)
    A.check("preset/abs", s.isValidPresetPath("/a/b/models.ini"), true)
    A.check("preset/relative", s.isValidPresetPath("a/b"), false)
    A.check("preset/dollar", s.isValidPresetPath("/$HOME/x"), false)
    A.check("preset/quote", s.isValidPresetPath('/a/"b"'), false)
    A.check("preset/backslash", s.isValidPresetPath("/a\\b"), false)
    A.check("preset/backtick", s.isValidPresetPath("/a/`b`"), false)

    A.check("truncate/short", s.truncate("abc", 4), "abc")
    A.check("truncate/exact", s.truncate("abcd", 4), "abcd")
    A.check("truncate/long", s.truncate("abcde", 4), "abcd\u2026")
    A.check("truncate/empty-input", s.truncate("", 4), "")
    A.finish()
  }
}