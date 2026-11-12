// Single source of truth for the feature list shown on the site.
// Only list features that exist in the app. Do not embellish.

export interface FeatureGroup {
  id: string;
  title: string;
  /** Optional short note shown next to the group title. */
  note?: string;
  items: string[];
}

export const featureGroups: FeatureGroup[] = [
  {
    id: 'recording',
    title: 'Recording',
    items: [
      'Record a whole display (choose which one when several are connected), a single window, or a selected area.',
      'Area selection by dragging, or presets: 1280×720, 1920×1080, 1080×1080 square, 1080×1920 vertical. A red outline marks the area and never appears in the video.',
      'Native (Retina) or Standard (1x) resolution.',
      'Camera, microphone and system audio, each with its own switch.',
      'Every source is kept separate: the screen file carries system audio and microphone as two separate audio tracks; the camera is its own file.',
      'Constant frame rate HEVC video (30 fps by default), Rec. 709.',
      'Uncompressed 24-bit 48 kHz audio, gapless.',
      'The screen, audio and camera files start at the same instant and carry timecode, so layers line up on a timeline.',
      "The app's own windows (timer, outline, countdown) are excluded from the recording.",
    ],
  },
  {
    id: 'during',
    title: 'Before and during recording',
    items: [
      'Live previews: screen thumbnail, camera picture (mirrored by default, with an option to turn mirroring off; the recording itself is never mirrored), and scrolling audio waveforms with dB readouts that turn red near clipping.',
      '3-second countdown that you can click to cancel.',
      'Floating timer with a Stop button. You can also stop from the menu bar or the Dock icon.',
      'Menu bar panel with source switches, capture mode, resolution, status and elapsed time.',
      'Quitting mid-recording finishes the files first, so nothing is left corrupt.',
    ],
  },
  {
    id: 'cursor',
    title: 'Cursor effects',
    items: [
      "The pointer's position and every click are logged during recording (120 times a second).",
      'Cursor highlight with adjustable colour, size and opacity.',
      'Click ripples with separate colours for left and right clicks.',
      'Live preview in the review window. Effects are rendered as a separate transparent layer and the screen video is never altered.',
    ],
  },
  {
    id: 'camera',
    title: 'Camera',
    items: [
      'Background removal, done on-device.',
      'Rectangle or circle shape.',
      'Picture-in-picture size and corner (top or bottom, left or right).',
      'Rendered as a separate transparent file; the original camera recording is untouched.',
    ],
  },
  {
    id: 'resolve',
    title: 'DaVinci Resolve handoff',
    note: 'Needs DaVinci Resolve Studio',
    items: [
      "One click creates a Resolve project with the timeline set to the recording's frame rate and resolution.",
      'Screen on V1, cursor effects on V2, camera picture-in-picture on V3, already sized and positioned; system audio on A1 and microphone on A2.',
      'Saves the project you had open before switching, and refuses to proceed if an unsaved project holds work.',
    ],
  },
  {
    id: 'other-editors',
    title: 'Any other editor',
    items: [
      'Export the cursor effects layer and the camera cutout as ProRes 4444 video with transparency, usable in any editor that supports alpha.',
    ],
  },
  {
    id: 'automation',
    title: 'Automation',
    items: [
      'Command-line options for scripted recordings: duration, frame rate (1–120), output folder, area, window by app name, source switches, plus rendering layers and creating a Resolve project for an existing recording.',
    ],
  },
];
