// Files CaptureDesktop writes for each recording, and known limits.

export const outputFolder = 'A dated folder in Movies/CaptureDesktop';

export const outputFiles: { name: string; description: string }[] = [
  { name: 'screen.mov', description: 'Screen video, with system audio and microphone as two separate audio tracks.' },
  { name: 'audio.mov', description: 'Audio only, written when the screen is not recorded.' },
  { name: 'camera.mov', description: 'Camera video, as its own file.' },
  { name: 'cursor.jsonl', description: 'Pointer positions and clicks.' },
  { name: 'session.json', description: 'Settings and a summary of the session.' },
  { name: 'cursor-effects-<tag>.mov', description: 'Rendered cursor effects layer, ProRes 4444 with transparency.' },
  { name: 'camera-cutout-<tag>.mov', description: 'Rendered camera cutout layer, ProRes 4444 with transparency.' },
];

export const outputSizeNote =
  'Rendered layers are large: roughly 95 MB per minute for cursor effects and 600 MB per minute for the camera cutout.';

export const knownLimits: string[] = [
  'No built-in editor, by design. Editing happens in Resolve or another editor.',
  'The Resolve handoff needs DaVinci Resolve Studio. The free version does not allow external scripting.',
  'The global shortcut is fixed at ⌥⇧⌘R; if another app already uses it, it does nothing.',
  'The selected area is not remembered between launches.',
];
