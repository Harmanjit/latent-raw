# Accessibility

Latent follows three macOS settings: VoiceOver, Reduce Motion and Increase Contrast. They take effect without relaunching. The gaps that remain are listed at the end and on [Limitations](Limitations).

## Keyboard

Every command is in the menu bar, with its key; see [Keyboard Shortcuts](Keyboard-Shortcuts). With Full Keyboard Access on, Tab reaches buttons and switches, and Space and Return press the focused one; the arrow keys still step through images. It also reaches sliders, which ← and → then move. Tab reaches the folder sidebar too: ↑ and ↓ move through it, → and ← expand and collapse, typing a name jumps to it, and Return or Space opens the selected folder. A click in the sidebar leaves the keys with the images. Slider values can be typed: click the number beside a slider (see [Develop](Develop)).

## VoiceOver

- **Controls have names.** Buttons drawn as symbols (rotate, zoom, delete, dismiss) are read by what they do, and sliders by their names, with values read as the panel shows them (temperature in kelvin, exposure in EV).
- **Ratings are one control.** The left panel's stars read as "Rating, 3 stars" and the filter bar's as "Minimum rating, 3 stars or more"; both are adjustable, so swipe up or down (VO-↑ and VO-↓) to change them. Flags read as Picked, Rejected or Unflagged.
- **Images read as one line.** A grid cell or filmstrip frame reads its file name, flag, stars and whether it is edited, as in "DSC_0107.NEF, picked, 3 stars, edited"; a grid cell adds its Finder tags ("tagged Red, Work"). A grid cell's actions (VO-⌘-Space) rate it, from Clear rating to Rate 5 stars, as clicking its stars does. Filmstrip frames can be pressed to open them, and so can sidebar folders; the sidebar's context menu (VO-⇧-M) acts on the folder under the VoiceOver cursor. The Back and Forward buttons atop the sidebar read the folder they go to.
- **On-image tools.** The crop rectangle reads its size, aspect and angle, and has a Reset crop action. Spot removal patches read how many there are and which is selected; adjust to step the selection through them, and use the Delete selected patch action. Red-eye spots work the same way, with a Delete selected spot action, and the panel's Auto button adds spots without a pointer; what it found is announced.
- **Survey.** Each pane reads as "Survey pane 2 of 3", with Focused on the one the keys act on, and has Focus and Remove from Survey actions.
- **Full-screen image.** The panels that come in from the screen's edges can't be reached without a pointer, so the image area's actions offer Show Library Panel, Show Adjustments and Show Filmstrip (and Hide while one is open).
- **Other windows.** The Loupe on a second display reads the image's name. In the export quality comparison, each pane reads the image and its quality and has Pan left, right, up and down actions, and each Use button says which quality it sets. The slideshow reads each slide's file name and position ("Slideshow, DSC_0107.NEF, 3 of 20"), announces each slide, and announces Slideshow paused and Slideshow playing; its buttons are labelled. The Rename sheet's field says the extension is kept.
- **Readouts.** The histogram reads where the pixels sit ("shadows 20 percent, midtones 65 percent, highlights 15 percent"), and the clipping lines read per channel. History steps and mask rows are buttons that say which one is selected.
- **Announcements.** Errors that appear in the status bar are announced, and so is the end of an export: a batch with how many were exported and how many failed, a single image with its result. So are the end of a move or copy, a finished contact sheet, and a second display being unplugged. The status bar's progress for moves and copies reads as, for example, "Moving, 3 of 12", beside a Stop button.

## Reduce Motion

Animations in the main window, the export sheet, Settings and Help are dropped: disclosure groups open, panels appear and the sidebar collapses in one step. The filmstrip jumps to the current image instead of gliding. In full-screen image mode the panels fade in and out instead of sliding, and the system's full screen cross-fades. The slideshow's Push and Zoom transitions become a cross-fade (Cut and the fades stay as chosen), and its caption and buttons appear without fading.

## Increase Contrast

A selection gets a solid accent outline over its tinted fill: the selected grid cell, sidebar row, history step, mask row, spot removal patch and red-eye spot. Survey's focused pane gets a thicker outline, and the ✕ that removes a pane a darker backing.

## Not yet

- Grid cells have no VoiceOver action to open an image; select the cell, then press Return or use the View menu.
- The waveform and vectorscope are named but not described.
- Compare shows no focus highlight for the pane the keys act on (always the Candidate, on the right).
- Placing a spot patch or brush stroke, placing a red-eye spot by hand, drawing a gradient, radial or brush mask, clicking to select a subject, and moving the crop rectangle need a pointer.
- Arranging a Custom sort needs dragging, and so does dropping images on a sidebar folder; File > Move to Folder… and Copy to Folder… do the latter from the keyboard.
- The magnifier needs a mouse button held down; ⌘1 and Z show 100% instead. Trackpad swipes have the arrow keys.
