import Catalog
import PixelEngine

extension ImageRecord {
    /// The photo's title, caption, creator and copyright as an export
    /// writes them (`ExportDescription`).
    var exportDescription: ExportDescription {
        ExportDescription(title: title, caption: caption, creator: creator, copyright: copyright)
    }
}
