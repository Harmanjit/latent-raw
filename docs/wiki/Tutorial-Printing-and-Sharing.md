# Tutorial: Printing and Sharing

Two walkthroughs for getting photos out of Latent: preparing a print with soft proofing, and exporting for the web with a watermark. The controls are described in full on [Export](Export) and under [Soft proofing](Develop#soft-proofing).

## Soft proof and export for print

A screen glows; paper doesn't. Soft proofing shows on screen what a print will look like, so you can adjust before you spend ink and paper.

**1. Get the paper's profile.** Paper makers and print labs publish an ICC profile for each printer and paper. Download it from their site in your browser and put it in the Mac's shared ColorSync folder, **/Library/ColorSync/Profiles** (the Library folder at the top of the disk, not the one in your home folder); Finder asks for your password. Printer installers often put profiles there already. Latent lists the profiles in that folder; a profile kept anywhere else can still be chosen by hand, with **Add Profile…** in Soft Proof (which then keeps it in its menu) or **Other…** in the export sheet.

**2. Optional: make a print version.** Select the photo and press **⌘'** to make a virtual copy. Proof and adjust the copy, and your screen version stays as it is. See [Virtual copies](Library#virtual-copies).

**3. Switch on the proof.** In Develop, open **Soft Proof** at the bottom of the adjustments, tick **Soft proof** (or press **S**), and pick the paper's profile from the target menu, under **Installed Profiles**, or with **Add Profile…**.

**4. Choose an intent.** **Perceptual** squeezes all the colours into what the paper can show, keeping their relationships. **Relative Colorimetric** keeps every colour that fits exactly and clips the rest. Flip between them and keep the one that looks better.

**5. See the paper as it is.** Tick **Simulate Paper & Ink**. The proof turns duller and slightly tinted: that is the paper's real white and the ink's real black. Judge contrast and shadows with it on.

**6. Find the problem colours.** **Destination gamut warning** paints red the colours the paper can't reproduce; **Monitor gamut warning** paints blue the ones your screen can't show either.

**7. Adjust for the paper.** Typical fixes: lift **Shadows** or **Blacks** a little, since paper blocks up dark tones; lower **Saturation** or **Vibrance**, or use HSL, on colours the warning marks red. The proof updates as you drag.

**8. Keep the proofed edit.** Click **Create Proof Copy**. It saves the edit as a snapshot named after the paper, such as "Proof — Canson Rag Photographique", in the history panel's snapshot list.

**9a. Print it yourself.** Press **⌘P** (**File › Print…**). With Soft Proof on, the print's **Colour** starts at the paper's profile and the **Rendering intent** at the one you chose, so the print matches the proof. **Photo Layout** in the print panel sets how many photos per page, margins and captions. See [Print](Export#print).

**9b. Or export for a lab.** Select the photo in the Library and press **⇧⌘E**. Then:

- **Format**: TIFF, 16 bits per channel (or JPEG at high quality, if the lab asks for it).
- **Colour space**: the lab's profile if it gave you one (installed profiles are listed; **Other…** picks a profile file), otherwise **Adobe RGB (1998)**, which is what labs usually ask for.
- **Resize to fit**: the print size in pixels, or leave it off for full size; **Resolution**: 300 ppi, or what the lab asks.
- **Sharpen for**: **Matte paper** or **Glossy paper**, at **Standard**.
- Click **Save current as preset…** and name it after the lab, so the next print is one click.

## Export for the web with a watermark

**1. Select and open the sheet.** Select the photos in the Library and press **⇧⌘E** (**File › Export**).

**2. Start from the web preset.** Choose the built-in preset **Web (2048 px JPEG)**; then change what you need.

**3. Format and quality.** **JPEG** is read everywhere. A quality around 80 is usually indistinguishable from the maximum at a fraction of the size; click **Compare…** to see two to four qualities side by side at 100%. If a site limits file size, tick **Limit file size to** and give the limit in KB.

**4. Colour space.** **sRGB**, which looks right on any screen and in any browser.

**5. Size.** Tick **Resize to fit**, choose **Long edge** and type the size the site recommends, say 2048. Keep **Don't enlarge** on.

**6. Sharpening.** Tick **Sharpen for**, choose **Screen** at **Standard**. It makes up for the softening a smaller size brings.

**7. Metadata.** **Copyright only** keeps your copyright notice and nothing else; **All except camera info** also keeps the title, caption and keywords that help photo sites. Leave **Include location** off unless you mean to share where the photo was taken.

**8. Watermark.** Tick **Watermark**, choose **Text**, and type something like `© {year} Ann Smith` (`{year}` becomes the year the photo was taken). Pick the **Corner**, the size and the **Opacity**; a size of 2–3% and an opacity around 60% is discreet. For a logo, choose a **Graphic** instead and pick a PNG with a transparent background.

**9. Name and place the files.** Set the name template, for example `{date}-{seq}`, choose where to **Export to**, and type `web` as a **Subfolder** to keep these apart.

**10. Save it and export.** Click **Save current as preset…** and name it, say "Web with watermark", then **Export**. Progress shows in the left panel.

**Next time.** Select the new photos and press **⌥⇧⌘E** (**File › Export with Previous**) to export them with exactly the same settings, without the sheet. To make web and print files in one go, tick several saved presets under **Export with several presets** at the top of the sheet.
