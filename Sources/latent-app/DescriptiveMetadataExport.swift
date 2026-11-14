import Catalog
import PixelEngine

extension ImageRecord {
    /// The photo's title, caption, creator and copyright as an export
    /// writes them (`ExportDescription`), with the More fields (headline,
    /// location, contact details, instructions) beside them.
    var exportDescription: ExportDescription {
        ExportDescription(title: title, caption: caption, creator: creator, copyright: copyright)
            .with(more: ExportDescription.More(
                headline: headline, sublocation: sublocation, city: city, state: state, country: country,
                countryCode: countryCode, creatorJobTitle: creatorJobTitle, creatorEmail: creatorEmail,
                creatorURL: creatorURL, instructions: instructions))
    }
}
