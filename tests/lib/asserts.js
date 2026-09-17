.pragma library

// Minimal QML test assertion helpers for the quickshell -p harnesses.
// The driver copies this file next to each harness and substitutes
// @SERVICE_QML_PATH@ with the absolute file:// URL of the Service.qml to load.
// Output protocol (one console line each):
//   LAD-PASS  <name>
//   LAD-FAIL  <name>  got=<json> expected=<json>
//   LAD-SUMMARY:<total>:<failures>

var _results = []

function _record(name, pass, actual, expected) {
  _results.push({ name: name, pass: pass, actual: actual, expected: expected })
}

function check(name, actual, expected) {
  _record(name, JSON.stringify(actual) === JSON.stringify(expected), actual, expected)
}

function ok(name, cond) { _record(name, !!cond, cond, true) }

function notok(name, cond) { _record(name, !cond, cond, false) }

function fail(name) { _record(name, false, "assert", "pass") }

// Instantiate Service.qml. `Qt` is a JS global binding (available even inside
// a .pragma library); QML types like `Component` are not.
function service(path, parent, backend) {
  var comp = Qt.createComponent(path)
  if (comp.status !== 1) {
    console.log("LAD-FAIL  service-compiles  got=compile-error expected=Ready");
    console.log("LOAD-ERROR: " + comp.errorString());
    _record("service-compiles", false, comp.errorString(), "Ready")
    finish()
    return null
  }
  var s = comp.createObject(parent, { backend: backend || "llama.cpp" })
  if (!s) {
    _record("service-instantiates", false, null, "object")
    finish()
    return null
  }
  return s
}

// Walk an object subtree, collecting every QQuickItem (and QObject with data).
function collect(objects, into) {
  var list = objects || []
  for (var i = 0; i < list.length; i++) {
    var o = list[i]
    if (!o) continue
    into.push(o)
    var kids = o.data || o.children || []
    if (kids.length) collect(kids, into)
  }
  return into
}

function finish() {
  var fails = 0
  for (var i = 0; i < _results.length; i++) {
    var r = _results[i]
    var line = (r.pass ? "LAD-PASS  " : "LAD-FAIL  ") + r.name
    if (!r.pass) line += "  got=" + JSON.stringify(r.actual) + " expected=" + JSON.stringify(r.expected)
    console.log(line)
    if (!r.pass) fails++
  }
  console.log("LAD-SUMMARY:" + _results.length + ":" + fails)
  Qt.quit()
}