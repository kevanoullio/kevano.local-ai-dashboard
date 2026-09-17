import QtQuick
import Quickshell
import "asserts.js" as A

// Unit: _parseConfigBuffer is the pure parser that turns the config reader's
// output into the applied host/port/key/valid flags. It must never let an
// invalid config through: every violation resets to safe defaults + warning.
Item {
  id: root
  Component.onCompleted: {
    var s = A.service("@SERVICE_QML_PATH@", root, "llama.cpp")
    function parse(buf) { s._configBuffer = buf; s._parseConfigBuffer() }

    parse("NO\n")
    A.check("no/hasConfig", s.hasConfig, false)
    A.check("no/host-default", s.configHost, "127.0.0.1")
    A.check("no/port-default", s.configPort, 0)
    A.check("no/key-default", s.configApiKey, "")
    A.check("no/valid", s.configValid, true)
    A.check("no/warning-clear", s.configWarning, "")

    parse("REFUSE\n")
    A.check("refuse/hasConfig", s.hasConfig, false)
    A.check("refuse/host-safe", s.configHost, "127.0.0.1")
    A.check("refuse/port-safe", s.configPort, 0)
    A.check("refuse/valid", s.configValid, true)
    A.check("refuse/warning", s.configWarning.indexOf("Refusing to read config") !== -1, true)

    parse("HAS\nLLAMA_HOST=127.0.0.1\nLLAMA_PORT=8080\nLLAMA_API_KEY=\"sekret\"\nLLAMA_EXTRA_ARGS=--temp 0.7\n")
    A.check("valid/hasConfig", s.hasConfig, true)
    A.check("valid/host", s.configHost, "127.0.0.1")
    A.check("valid/port", s.configPort, 8080)
    A.check("valid/key-unquoted", s.configApiKey, "sekret")
    A.check("valid/flag", s.configValid, true)
    A.check("valid/warning-clear", s.configWarning, "")

    parse("HAS\nLLAMA_PORT=99999\n")
    A.check("port-oob/valid", s.configValid, false)
    A.check("port-oob/host-safe", s.configHost, "127.0.0.1")
    A.check("port-oob/port-safe", s.configPort, 0)
    A.check("port-oob/warning", s.configWarning.indexOf("LLAMA_PORT out of range") !== -1, true)

    parse("HAS\nLLAMA_EXTRA_ARGS=--x;rm -rf /\n")
    A.check("extraargs/valid", s.configValid, false)
    A.check("extraargs/warning", s.configWarning.indexOf("unsafe characters") !== -1, true)

    parse("HAS\nLLAMA_HOST=0.0.0.0\n")
    A.check("host-nonloopback/valid", s.configValid, false)
    A.check("host-nonloopback/warning", s.configWarning.indexOf("host is not a valid loopback or remote host") !== -1, true)

    parse("HAS\n")
    A.check("empty-has/valid", s.configValid, true)
    A.check("empty-has/host", s.configHost, "127.0.0.1")
    A.check("empty-has/port", s.configPort, 0)

    var o = A.service("@SERVICE_QML_PATH@", root, "ollama")
    o._configBuffer = "HAS\n{\"host\":\"127.0.0.1\",\"port\":11434,\"api-key\":\"k\"}\n"
    o._parseConfigBuffer()
    A.check("ollama/hasConfig", o.hasConfig, true)
    A.check("ollama/host", o.configHost, "127.0.0.1")
    A.check("ollama/port", o.configPort, 11434)
    A.check("ollama/key", o.configApiKey, "k")
    A.check("ollama/valid", o.configValid, true)

    o._configBuffer = "HAS\nnot json\n"
    o._parseConfigBuffer()
    A.check("ollama-bad-json/valid", o.configValid, false)
    A.check("ollama-bad-json/warning", o.configWarning.indexOf("not valid JSON") !== -1, true)
    A.finish()
  }
}