#!/usr/bin/env python3
"""Create a DaVinci Resolve project from a CaptureDesktop recording folder.

Usage: resolve_project.py <recording-folder> <project-name> [options-json]

options-json may hold "cursorEffectsFile": the name of the transparent cursor
layer to put above the screen ("" for none; without the key no cursor layer is
used), and a "camera" object: {"file": name of the camera file to
use, "size": width as a fraction of the screen, "margin": gap as a fraction of
the screen width, "left": bool, "top": bool, "square": bool (the visible
picture is a centred square, e.g. a circular crop)}.

Needs DaVinci Resolve Studio (the free version does not allow external
scripting) with Preferences > System > General > "External scripting using"
set to Local. RESOLVE_SCRIPT_API and RESOLVE_SCRIPT_LIB must be set.

Prints one JSON object on the last line of stdout:
  {"ok": true, "project": "..."}  or  {"ok": false, "error": "..."}
Exit code 3 means this Python cannot load Resolve's scripting module, so the
caller may retry with another interpreter.
"""
import json
import os
import sys
import time


def finish(ok, code=0, **fields):
    print(json.dumps(dict(ok=ok, **fields)))
    sys.exit(code)


def place_camera(item, clip_item, width, height, options):
    """Size the camera as a picture-in-picture and move it to the chosen corner."""
    try:
        clip_width, clip_height = [float(v) for v in clip_item.GetClipProperty("Resolution").lower().split("x")]
    except (AttributeError, ValueError):
        clip_width, clip_height = 1920.0, 1080.0
    # Resolve first fits the clip inside the timeline frame; zoom is relative to that.
    fit = min(width / clip_width, height / clip_height)
    # A circular crop shows a centred square whose side is the clip's smaller dimension.
    side = min(clip_width, clip_height)
    visible_width = side if options.get("square") else clip_width
    visible_height = side if options.get("square") else clip_height
    target_width = width * float(options.get("size", 0.25))
    zoom = target_width / (visible_width * fit)
    shown_width = target_width
    shown_height = visible_height * fit * zoom
    margin = width * float(options.get("margin", 0.015))
    pan = width / 2.0 - shown_width / 2.0 - margin
    tilt = height / 2.0 - shown_height / 2.0 - margin
    results = [
        item.SetProperty("ZoomX", zoom),
        item.SetProperty("ZoomY", zoom),
        item.SetProperty("Pan", -pan if options.get("left") else pan),
        item.SetProperty("Tilt", tilt if options.get("top") else -tilt),
    ]
    return all(results)


def main():
    if len(sys.argv) not in (3, 4):
        finish(False, 2, error="usage: resolve_project.py <recording-folder> <project-name> [options-json]")
    folder, name = sys.argv[1], sys.argv[2]
    options = json.loads(sys.argv[3]) if len(sys.argv) == 4 else {}
    camera_options = options.get("camera") or {}

    api = os.environ.get("RESOLVE_SCRIPT_API", "")
    sys.path.insert(0, os.path.join(api, "Modules"))
    try:
        import DaVinciResolveScript as dvr
    except Exception as error:  # ImportError, or a binary that does not match this Python
        finish(False, 3, error="Could not load Resolve's scripting module: %s" % error)

    # Resolve may still be starting: wait until the project manager answers.
    resolve = manager = None
    deadline = time.time() + float(os.environ.get("CAPTUREDESKTOP_RESOLVE_WAIT", "120"))
    while time.time() < deadline:
        try:
            resolve = dvr.scriptapp("Resolve")
            manager = resolve.GetProjectManager() if resolve else None
        except Exception:
            manager = None
        if manager:
            break
        time.sleep(2)
    if not manager:
        finish(False, 1, error="Could not connect to DaVinci Resolve. External scripting needs DaVinci Resolve "
                               "Studio, with Preferences > System > General > External scripting using set to Local.")

    with open(os.path.join(folder, "session.json")) as handle:
        session = json.load(handle)
    kinds = ("screen", "audio", "cursor-effects", "camera")
    paths = {key: os.path.join(folder, key + ".mov") for key in ("screen", "audio", "camera")}
    # Rendered layers are named per look, so the caller says exactly which files to use.
    if camera_options.get("file"):
        paths["camera"] = os.path.join(folder, os.path.basename(camera_options["file"]))
    if options.get("cursorEffectsFile"):
        paths["cursor-effects"] = os.path.join(folder, os.path.basename(options["cursorEffectsFile"]))
    missing = [os.path.basename(paths[key]) for key in ("cursor-effects",) if key in paths and not os.path.exists(paths[key])]
    if camera_options.get("file") and not os.path.exists(paths["camera"]):
        missing.append(os.path.basename(paths["camera"]))
    if missing:
        finish(False, 1, error="Missing file(s) in the recording folder: %s" % ", ".join(missing))
    paths = {key: path for key, path in paths.items() if os.path.exists(path)}
    if not paths:
        finish(False, 1, error="No recording files found in %s" % folder)

    # Keep whatever was open safe before switching projects.
    existing = set(manager.GetProjectListInCurrentFolder() or [])
    current = manager.GetCurrentProject()
    # Only projects that already exist on disk can be saved; saving the blank
    # "Untitled Project" Resolve opens with blocks project creation.
    if current and current.GetName() not in existing:
        # A project that was never saved (Resolve's blank "Untitled Project") cannot be
        # saved from a script. If it holds work, stop rather than switch away from it.
        pool_root = current.GetMediaPool().GetRootFolder() if current.GetMediaPool() else None
        has_work = current.GetTimelineCount() > 0 or bool(pool_root and (pool_root.GetClipList() or pool_root.GetSubFolderList()))
        if has_work:
            finish(False, 1, error="The project open in DaVinci Resolve (\"%s\") has unsaved work and has never "
                                   "been saved. Save it in Resolve, then try again." % current.GetName())
    elif current and not manager.SaveProject():
        finish(False, 1, error="DaVinci Resolve could not save the open project \"%s\", so no new project "
                               "was created. Save or close it in Resolve and try again." % current.GetName())
    project_name, suffix = name, 1
    while project_name in existing:
        suffix += 1
        project_name = "%s %d" % (name, suffix)
    # Right after launch Resolve answers but refuses to create projects for a few seconds.
    project = None
    while not project and time.time() < deadline:
        project = manager.CreateProject(project_name)
        if not project:
            time.sleep(2)
    if not project:
        finish(False, 1, error="DaVinci Resolve would not create the project")

    # Frame rate and size must be set before the first timeline exists.
    def applied(key, wanted):
        """True when the project setting now holds `wanted` (compared as numbers)."""
        try:
            return abs(float(project.GetSetting(key)) - float(wanted)) < 0.01
        except (TypeError, ValueError):
            return False

    fps = str(session.get("fps", 30))
    project.SetSetting("timelineFrameRate", fps)
    project.SetSetting("timelinePlaybackFrameRate", fps)
    capture = session.get("capture") or {}
    width, height = capture.get("pixelWidth"), capture.get("pixelHeight")
    wanted = {"timelineFrameRate": fps}
    if "screen" in paths and width and height:
        project.SetSetting("timelineResolutionWidth", str(width))
        project.SetSetting("timelineResolutionHeight", str(height))
        wanted.update(timelineResolutionWidth=width, timelineResolutionHeight=height)
    # Read the settings back: a rejected value would silently leave Resolve's defaults.
    for key, value in wanted.items():
        if not applied(key, value):
            finish(False, 1, project=project_name,
                   error="DaVinci Resolve rejected %s = %s in project \"%s\"" % (key, value, project_name))

    pool = project.GetMediaPool()
    order = [key for key in kinds if key in paths]
    imported = pool.ImportMedia([paths[key] for key in order]) or []
    by_name = {os.path.basename(path): key for key, path in paths.items()}
    items = {}
    for item in imported:
        if item.GetName() in by_name:
            items[by_name[item.GetName()]] = item
    if len(items) != len(order):
        finish(False, 1, project=project_name, error="DaVinci Resolve could not import every file")

    # Building the timeline from the main clip gives every audio track in the
    # file its own timeline track (system audio on A1, microphone on A2);
    # appending the clip afterwards would only bring the first one.
    primary = "screen" if "screen" in items else ("audio" if "audio" in items else None)
    if primary:
        timeline = pool.CreateTimelineFromClips(project_name, [items[primary]])
    else:
        timeline = pool.CreateEmptyTimeline(project_name)
    if not timeline:
        finish(False, 1, project=project_name, error="DaVinci Resolve would not create a timeline")
    project.SetCurrentTimeline(timeline)
    start = timeline.GetStartFrame()

    def clip(key, track, media_type=None):
        info = {"mediaPoolItem": items[key], "trackIndex": track, "recordFrame": start}
        try:
            frames = int(items[key].GetClipProperty("Frames"))
            info.update(startFrame=0, endFrame=frames)
        except (TypeError, ValueError):
            pass
        if media_type:
            info["mediaType"] = media_type
        return info

    # Every file starts at the same instant, so each layer lines up at the timeline start.
    def require(result, what):
        if not result:
            finish(False, 1, project=project_name,
                   error="DaVinci Resolve could not %s in project \"%s\"" % (what, project_name))
        return result

    track = 1
    if primary == "screen" and "cursor-effects" in items:
        # Transparent highlight layer, directly above the screen recording.
        track += 1
        require(timeline.AddTrack("video"), "add a video track for the cursor effects")
        require(pool.AppendToTimeline([clip("cursor-effects", track, 1)]), "place the cursor effects layer")
    if "camera" in items:
        if primary == "screen":
            track += 1
            require(timeline.AddTrack("video"), "add a video track for the camera")
            placed = require(pool.AppendToTimeline([clip("camera", track, 1)]), "place the camera")
            if width and height:
                require(place_camera(placed[0], items["camera"], width, height, camera_options),
                        "size and position the camera")
        else:
            require(pool.AppendToTimeline([clip("camera", 1, 1)]), "place the camera")

    resolve.OpenPage("edit")
    require(manager.SaveProject(), "save the project")
    finish(True, project=project_name)


if __name__ == "__main__":
    main()
