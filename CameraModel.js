.pragma library

// Reads the user's camera list from ~/.config/omarchy/plugins/<id>/cameras.json
// and builds RTSP stream URLs for each camera.
//
// cameras.json format (see cameras.json.example):
// [
//   { "name": "Front Door", "ip": "192.168.1.50", "username": "camuser", "password": "campass", "port": 554, "stream": "stream1" }
// ]
//
// "username"/"password" are the *camera account* credentials you set in the
// Tapo app under Advanced Settings -> Camera Account (NOT your TP-Link
// cloud login). "stream" is "stream1" (HD) or "stream2" (SD).

function rtspUrl(camera) {
    var port = camera.port || 554;
    var stream = camera.stream || "stream1";
    var user = encodeURIComponent(camera.username || "");
    var pass = encodeURIComponent(camera.password || "");
    return "rtsp://" + user + ":" + pass + "@" + camera.ip + ":" + port + "/" + stream;
}

function parseCameras(jsonText) {
    var list = [];
    try {
        list = JSON.parse(jsonText);
    } catch (e) {
        console.warn("[tapo-cameras] failed to parse cameras.json:", e);
        return [];
    }
    if (!Array.isArray(list)) return [];
    return list.map(function (cam) {
        return {
            name: cam.name || cam.ip,
            ip: cam.ip,
            username: cam.username || "",
            password: cam.password || "",
            port: cam.port || 554,
            stream: cam.stream || "stream1",
            url: rtspUrl(cam)
        };
    });
}
