import Foundation

/// The photo-scan prompt and its JSON schema, kept together in one reviewable file
/// (PLAN §6.2 step 2). The prompt is deliberately conservative: read one tile in
/// isolation, skip unreadable spines rather than guess, omit non-game items, and
/// never pattern-complete from memory of other photos (each tile is its own isolated
/// `claude -p` call — see docs/ACCEPTANCE.md "Lesson for the M6 recogniser").
enum ShelfRecognitionPrompt {

    /// Spine-banner → platform legend given to the model (PLAN §6.2).
    static let platformLegend = """
    Platform is read from the coloured banner strip printed along the spine, mapped to \
    these VGN platform slugs:
    - "ps5"     — PlayStation 5: white banner across the top of the spine
    - "ps4"     — PlayStation 4: blue banner
    - "ps3"     — PlayStation 3: black banner (older ones red/black)
    - "ps2"     — PlayStation 2: blue/silver classic banner
    - "xbox360" — Xbox 360: green or white banner with the green Xbox sphere
    - "xboxone" — Xbox One: black/green banner
    - "switch"  — Nintendo Switch: red banner across the top
    - "wii"/"wiiu" — Nintendo Wii / Wii U: white banner
    If the banner is not clearly readable, set "platform" to null rather than guessing.
    """

    /// The JSON Schema passed as `--json-schema`. Kept permissive on optional fields so
    /// a genuinely-unknown value can be null instead of forcing a guess.
    static let jsonSchema = """
    {
      "type": "object",
      "additionalProperties": false,
      "properties": {
        "items": {
          "type": "array",
          "items": {
            "type": "object",
            "additionalProperties": false,
            "properties": {
              "printedTitle": { "type": "string", "description": "The title exactly as printed on the spine, including a French or edition title." },
              "normalizedTitle": { "type": ["string", "null"], "description": "Your best guess at the canonical English title, or null if unsure." },
              "platform": { "type": ["string", "null"], "description": "VGN platform slug from the spine banner, or null." },
              "editionHints": { "type": "array", "items": { "type": "string" }, "description": "Edition markers: Collector's, GOTY, Deluxe, Steelbook, Complete..." },
              "isCompilation": { "type": "boolean", "description": "True if this box is a compilation / collection of multiple games." },
              "confidence": { "type": "number", "description": "0..1 how confident you are you read this spine correctly." },
              "spineIndex": { "type": ["integer", "null"], "description": "0-based left-to-right position of this box within the tile." },
              "xStart": { "type": ["number", "null"], "description": "Left edge of the box within the tile, 0..1." },
              "xEnd": { "type": ["number", "null"], "description": "Right edge of the box within the tile, 0..1." },
              "isGame": { "type": "boolean", "description": "True for video games; false for music DVDs, books or other non-game items." }
            },
            "required": ["printedTitle", "confidence", "isGame"]
          }
        }
      },
      "required": ["items"]
    }
    """

    /// The instruction text for one tile, referencing the tile by basename (the file
    /// is the only thing in the CLI's working directory).
    static func prompt(tileFileName: String) -> String {
        """
        Read the image file `\(tileFileName)` in the current directory. It is a \
        full-resolution crop of one horizontal band of a video-game shelf: a row of \
        game cases seen mostly edge-on (vertical spines), sometimes a front cover.

        List every distinct VIDEO GAME box you can read, left to right, as JSON \
        matching the provided schema.

        Rules — follow them exactly:
        1. Read ONLY what is in THIS image. Do not add games you cannot see, and do not \
           infer titles from what a shelf "usually" contains.
        2. If a spine's title is unreadable (glare, shadow, a plain steelbook with no \
           text, cut off at the edge), SKIP it. Never invent a title. It is correct to \
           return fewer items than there are boxes.
        3. Omit non-game items entirely (music CDs/DVDs, Blu-ray films, books) — set \
           nothing for them.
        4. "printedTitle" is the text as actually printed (keep French titles like \
           "Les Chevaliers de Baphomet" verbatim); "normalizedTitle" is your best guess \
           at the canonical English title (e.g. "Broken Sword: Shadow of the Templars").
        5. Note edition words in "editionHints" (Collector's, GOTY, Deluxe, Steelbook, \
           Complete, Remastered stays part of the title though).
        6. Set "isCompilation" true for collections (e.g. "The Yakuza Remastered \
           Collection", "God of War Collection").
        7. Give each box a left-to-right "spineIndex" and an approximate horizontal \
           span ("xStart"/"xEnd", 0..1 across the tile) so it can be located later.
        8. Set an honest "confidence" (0..1). Low is fine for a faint or partial spine.

        \(platformLegend)

        Return only the JSON object.
        """
    }
}
