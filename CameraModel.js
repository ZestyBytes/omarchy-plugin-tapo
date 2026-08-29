.pragma library

// Reads/writes the user's camera list at
// ~/.config/omarchy/plugins/<id>/cameras.json.
//
// cameras.json format (see cameras.json.example):
// [
//   { "name": "Front Door", "ip": "192.168.1.50", "username": "camuser",
//     "password": "campass", "port": 554, "stream": "stream1",
//     "previewStream": "stream2", "hidden": false, "ptz": true }
// ]
//
// "username"/"password" are the *camera account* credentials set in the
// Tapo app under Advanced Settings -> Camera Account (NOT the TP-Link cloud
// login). "stream" is "stream1" (HD) or "stream2" (SD) and is what opens in
// mpv when a preview is clicked. "previewStream" is the (usually lower-res)
// stream decoded for the live thumbnail grid — defaults to "stream2" so
// tiling several cameras at once doesn't mean decoding several HD feeds
// simultaneously, which is what was driving the panel's bandwidth/CPU use
// and preview flicker. "hidden" lets a camera stay configured but be tucked
// out of the main list. "ptz" shows/hides the pan/tilt overlay controls for
// cameras that don't support ONVIF PTZ (defaults on, since most Tapo
// cameras with a physical mount do).
//
// This file is edited two ways: by hand (bulk setup, scripting) and from
// the panel's settings view (Panel.qml), which round-trips through
// parseCameras -> in-memory edits -> serializeCameras -> FileView.setText.
// Both paths go through the same shape here so they never drift.

function rtspUrl(camera, streamOverride) {
    var port = camera.port || 554;
    var stream = streamOverride || camera.stream || "stream1";
    var user = encodeURIComponent(camera.username || "");
    var pass = encodeURIComponent(camera.password || "");
    return "rtsp://" + user + ":" + pass + "@" + camera.ip + ":" + port + "/" + stream;
}

// URL for the low(er)-res feed decoded by the grid preview thumbnail.
function previewUrl(camera) {
    return rtspUrl(camera, camera.previewStream || "stream2");
}

// Every camera, including hidden ones — the settings editor's source list.
function parseCameras(jsonText) {
    var list = [];
    try {
        list = jsonText && jsonText.trim() !== "" ? JSON.parse(jsonText) : [];
    } catch (e) {
        console.warn("[tapo-cameras] failed to parse cameras.json:", e);
        return [];
    }
    if (!Array.isArray(list)) return [];
    return list.map(function (cam) {
        var out = {
            name: cam.name || cam.ip || "",
            ip: cam.ip || "",
            username: cam.username || "",
            password: cam.password || "",
            port: cam.port || 554,
            stream: cam.stream || "stream1",
            previewStream: cam.previewStream || "stream2",
            hidden: cam.hidden === true,
            ptz: cam.ptz !== false
        };
        out.url = rtspUrl(out);
        out.previewUrl = previewUrl(out);
        return out;
    });
}

// The subset actually worth keeping when a new blank row hasn't been
// filled in yet (an add-camera stub with nothing typed).
function isBlank(camera) {
    return !camera.name && !camera.ip && !camera.username && !camera.password;
}

// Drops the computed `url` and any fully-blank stub rows, then formats for
// disk. Field order kept stable so diffs / hand-edits stay readable.
function serializeCameras(cameras) {
    var cleaned = cameras
        .filter(function (cam) { return !isBlank(cam); })
        .map(function (cam) {
            return {
                name: cam.name || "",
                ip: cam.ip || "",
                username: cam.username || "",
                password: cam.password || "",
                port: cam.port || 554,
                stream: cam.stream || "stream1",
                previewStream: cam.previewStream || "stream2",
                hidden: cam.hidden === true,
                ptz: cam.ptz !== false
            };
        });
    return JSON.stringify(cleaned, null, 2) + "\n";
}

function blankCamera() {
    return { name: "", ip: "", username: "", password: "", port: 554, stream: "stream1", previewStream: "stream2", hidden: false, ptz: true, url: "", previewUrl: "" };
}
