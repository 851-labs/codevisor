#if DEBUG
  import Foundation

  nonisolated enum DemoConversation {
    static let prompt =
      "Add skin tones to the emoji picker. Remember the last tone I pick, and keep it working on mobile."

    static let editedFile = "src/EmojiPicker.tsx"
    static let editTitle = "Edited EmojiPicker.tsx"

    static let reply = """
      Skin tones are in the picker.

      ### Pick a tone once
      A row of **six tones** sits above the grid. Every emoji with skin tone variants follows your choice.

      - Your last tone is remembered between visits
      - Emoji without tone variants stay as they are
      - Long-press an emoji on mobile to pick a tone for just that one

      ### Ready for your phone
      The tone row scrolls on small screens, and every target is at least 44 points.

      All **18 tests pass**. The preview is running at **localhost:3000**.
      """

    static let replyFirstLine = "Skin tones are in the picker."

    static let before = """
      export function EmojiPicker({ onPick }) {
        const emojis = useEmojis();
        return (
          <Grid>
            {emojis.map((emoji) => (
              <Cell key={emoji.id} onClick={() => onPick(emoji)}>
                {emoji.char}
              </Cell>
            ))}
          </Grid>
        );
      }
      """

    static let after = """
      export function EmojiPicker({ onPick }) {
        const emojis = useEmojis();
        const [tone, setTone] = useStoredTone();
        return (
          <Grid>
            <SkinTones value={tone} onChange={setTone} />
            {emojis.map((emoji) => (
              <Cell key={emoji.id} onClick={() => onPick(emoji.withTone(tone))}>
                {emoji.withTone(tone).char}
              </Cell>
            ))}
          </Grid>
        );
      }
      """
  }
#endif
