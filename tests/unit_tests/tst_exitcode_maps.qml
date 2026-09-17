import QtQuick
import Quickshell
import "asserts.js" as A

// Unit: the provisioner exit-code -> user-message map. Each documented code
// must produce the precise actionable text (not raw systemctl output), and the
// default must degrade to the generic start-failure / action classifier.
Item {
  id: root
  Component.onCompleted: {
    var s = A.service("@SERVICE_QML_PATH@", root, "llama.cpp")
    A.check("55/env-symlink", s._provisionError(55, "x").indexOf("refusing to write the config") !== -1, true)
    A.check("57/env-write", s._provisionError(57, "x").indexOf("environment file could not be written") !== -1, true)
    A.check("58/unit-dir-symlink", s._provisionError(58, "x").indexOf("directory is a symlink") !== -1, true)
    A.check("40/binary-missing", s._provisionError(40, "x").indexOf("not on PATH") !== -1, true)
    A.check("60/lock-held", s._provisionError(60, "x").indexOf("already provisioning") !== -1, true)
    A.check("61/unit-write", s._provisionError(61, "x").indexOf("could not be created") !== -1, true)
    A.check("62/verify-fail", s._provisionError(62, "x").indexOf("failed systemd-analyze verification") !== -1, true)
    A.check("63/rolled-back", s._provisionError(63, "x").indexOf("was restored") !== -1, true)
    A.check("default-no-output", s._provisionError(0, ""), "Failed to start " + s.backendDisplayName)
    A.check("default-classify-cancel", s._provisionError(0, "request dismissed").indexOf("cancelled") !== -1, true)
    A.check("default-classify-auth", s._provisionError(0, "not authorized").indexOf("not authorized to manage system services") !== -1, true)
    A.finish()
  }
}