# Accessibility

Latent follows three macOS settings: VoiceOver, Reduce Motion and Increase Contrast. They take effect without relaunching. The gaps that remain are listed at the end and on [Limitations](Limitations).

## Keyboard

Every command is in the menu bar, with its key; see [Keyboard Shortcuts](Keyboard-Shortcuts). With Full Keyboard Access on, Tab reaches buttons and switches, and Space and Return press the focused one; the arrow keys still step through images. It also reaches sliders, which ← and → then move. Tab reaches the folder sidebar too: ↑ and ↓ move through it, → and ← expand and collapse, typing a name jumps to it, and Return or Space opens the selected folder. A click in the sidebar leaves the keys with the images. Slider values can be typed: click the number beside a slider (see [Develop](Develop)).

## VoiceOver

- **Controls have names.** Buttons drawn as symbols (rotate, zoom, delete, dismiss) are read by what they do, and sliders by their names, with values read as the panel shows them (temperature in kelvin, exposure in EV).
- **Ratings are one control.** The left panel's stars read as "Rating, 3 stars" and the filter bar's as "Minimum rating, 3 stars or more"; both are adjustable, so swipe up or down (VO-↑ and VO-↓) to change them. Flags read as Picked, Rejected or Unflagged.
- **Images read as one line.** A grid cell or filmstrip frame reads its file name, flag, stars and whether it is edited, as in "DSC_0107.NEF, picked, 3 stars, edited". Filmstrip frames can be pressed to open them, and so can sidebar folders; the sidebar's context menu (VO-⇧-M) acts on the folder under the VoiceOver cursor.
- **On-image tools.** The crop rectangle reads its size, aspect and angle, and has a Reset crop action. Spot removal patches read how many there are and which is selected; adjust to step the selection through them, and use the Delete selected patch action.
- **Readouts.** The histogram reads where the pixels sit ("shadows 20 percent, midtones 65 percent, highlights 15 percent"), and the clipping lines read per channel. History steps and mask rows are buttons that say which one is selected.
- **Announcements.** Errors that appear in the status bar are announced, and so is the end of an export: a batch with how many were exported and how many failed, a single image with its result.

## Reduce Motion

Animations in the main window, the export sheet, Settings and Help are dropped: disclosure groups open, panels appear and the sidebar collapses in one step. The filmstrip jumps to the current image instead of gliding.

## Increase Contrast

A selection gets a solid accent outline over its tinted fill: the selected grid cell, sidebar row, history step, mask row and spot removal patch.

## Not yet

- Grid cells have no VoiceOver action to open an image or change its rating; select the cell, then use the keys or the left panel.
- The waveform and vectorscope are named but not described.
- Compare shows no focus highlight for the pane the keys act on (always the Candidate, on the right).
- Placing a spot patch, drawing a gradient, radial or brush mask, clicking to select a subject, and moving the crop rectangle need a pointer.
