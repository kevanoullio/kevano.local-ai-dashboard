import QtQuick
import Quickshell
import "asserts.js" as A

// Unit: backend descriptor constants and configPath resolution must match the
// panel contract (binary/service names, ports, health endpoints, self-managed
// flag). These are the values every other process stage is keyed off.
Item {
  id: root
  Component.onCompleted: {
    var oll = A.service("@SERVICE_QML_PATH@", root, "ollama")
    A.check("ollama/backend", oll.backend, "ollama")
    A.check("ollama/binary", oll.backendBinary, "ollama")
    A.check("ollama/service", oll.backendService, "ollama.service")
    A.check("ollama/port", oll.backendPort, 11434)
    A.check("ollama/health-endpoint", oll.backendHealthEndpoint, "http://127.0.0.1:11434/")
    A.check("ollama/config-file", oll.backendConfigFile, "ollama.json")
    A.check("ollama/self-managed", oll.selfManaged, false)
    A.check("ollama/configPath", oll.configPath.indexOf("/configs/ollama.json") !== -1, true)

    var llm = A.service("@SERVICE_QML_PATH@", root, "llama.cpp")
    A.check("llama/binary", llm.backendBinary, "llama-server")
    A.check("llama/service", llm.backendService, "llama.cpp.service")
    A.check("llama/port", llm.backendPort, 8080)
    A.check("llama/health-endpoint", llm.backendHealthEndpoint, "http://127.0.0.1:8080/health")
    A.check("llama/config-file", llm.backendConfigFile, "llama.env")
    A.check("llama/self-managed", llm.selfManaged, true)
    A.check("llama/backend-debug", llm.backendDebugArgs.indexOf("llama.cpp.service") !== -1, true)
    A.check("llama/env-default-host", llm.llamaEnvDefault.indexOf("LLAMA_HOST=127.0.0.1") !== -1, true)
    A.check("llama/configPath", llm.configPath.charAt(0) === "/", true)
    A.finish()
  }
}