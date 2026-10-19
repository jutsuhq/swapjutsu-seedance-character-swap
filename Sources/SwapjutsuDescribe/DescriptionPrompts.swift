import Foundation

/// The prompts `Describer` sends, as measured in a bake-off of local models:
/// one JSON object per answer, only what is visible, never who a person is. The examples in them are neutral ones,
/// none from a clip the prompts were tested on: a small model copies an example's words into its answer.
public enum DescriptionPrompts {
    public static let character = """
        You write the character part of a video-edit prompt from a reference image. Describe only what is visible in \
        the image; never name or guess who a person is.
        Reply with one JSON object and nothing else:
        {"noun": "one or two uppercase words for what it is: WOMAN, MAN, GIRL, BOY, CAT, DOG, ROBOT, ...",
         "pronoun": "her, his, its or their",
         "appearance": "one phrase: age range, apparent height, build and proportions (shoulders, waist, legs), \
        skin or fur, face shape, hair (colour, length, style), eyes, expression",
         "wardrobe": "every visible garment, accessory and shoe, top to bottom, with colours and patterns; empty for an \
        animal without clothes",
         "traits": "the 5 to 7 most recognisable visual traits of the face, hair, fur and clothes, comma-separated, \
        e.g. short curly red hair, freckles, yellow raincoat; never the pose or where it stands",
         "moving": "the parts that swing or flow when it moves, e.g. skirt, scarf and hair; empty when none",
         "outer": "the outermost layer worn over the rest (a coat, jacket, cardigan, cape, ...) with its colour and \
        length, e.g. knee-length tan trench coat; empty when there is none",
         "outer_state": "how that layer is worn in the image, closed (buttoned, zipped, belted) or open, and how it \
        moves, e.g. buttoned closed, its hem sways; empty when there is none"}
        """

    public static let location = """
        You write the location part of a video-edit prompt from a reference image. Describe only what is visible.
        Reply with one JSON object and nothing else:
        {"noun": "one uppercase word for the place: GARDEN, STREET, KITCHEN, BEACH, ...",
         "description": "one phrase with the main architecture or landscape, materials, notable features and their sides",
         "floor": "the ground where a person would stand",
         "light": "the light: source, direction, colour, softness"}
        """

    /// The beats prompt for `input`'s keyframes, with `PoseBeats`' moves given as fact and the replacement's
    /// `wardrobe`, when known, so the model can say which of the performer's actions it can't do as they are. With
    /// several replaced performers each gets their own moves and gaze, by where they stand.
    public static func beats(_ input: DescribeInput, wardrobe: String = "") -> String {
        let times = input.keyframes.map { String(format: "%.2f", $0.time) }.joined(separator: ", ")
        let moves = input.beats.isEmpty ? "(none measured)" : input.beats.joined(separator: "\n")
        let framing = input.framing.map { "It measured the framing as a \($0) for most of the clip.\n" } ?? ""
        let places = input.performers.count > 1 ? input.performers : []
        let each =
            places.isEmpty
            ? ""
            : """

            \(places.count) performers are replaced: the one \(places.joined(separator: ", the one ")). Each does \
            their own moves; say them apart, by where each one stands.
            """
        let gaze = places.isEmpty
            ? """
            ,
             "gaze": "where the performer looks for most of the clip, in a few words, e.g. at the person beside them, \
            down at the floor, into the camera, up at the sky"
            """
            : places.enumerated().map { index, place in
                """
                ,
                 "moves_\(index + 1)": "the moves of the performer \(place) only: 2 to 4 short beat phrases in time \
                order, what their body, arms and hands do",
                 "gaze_\(index + 1)": "where the performer \(place) looks for most of the clip, in a few words"
                """
            }.joined()
        return """
            These \(input.keyframes.count) frames are from a \(String(format: "%.1f", input.seconds)) s video, at \
            \(times) s. A body-pose tracker measured these moves of the main performer:
            \(moves)
            \(framing)Write the movement part of a video-edit prompt. Use the tracker's moves and times as fact; add only what \
            the frames show (the activity, the kind of step, the gesture, the direction of a turn, where they look, \
            what they do with the things around them). Never describe or name who the people are; say "their" for \
            a performer, never "his" or "her".\(each)
            The performer is replaced by a character who wears: \(wardrobe.isEmpty ? "(unknown)" : wardrobe). So say \
            what the body does, never the performer's own clothes, pockets or accessories: write "hand at the hip", \
            not "hand in the coat pocket".
            Reply with one JSON object and nothing else:
            {"camera": "the camera angle and how it moves, judged by the background from frame to frame: static only \
            when the background stays in place in every frame; else handheld, panning, tilting, tracking (moving \
            with the performer), pushing in or pulling out",
             "performer": "a neutral label for the main performer by role and action, e.g. the man jogging forward",
             "shot": "how much of the performer the frame shows (close-up, chest-up, waist-up, knees-up, full-body or \
            wide) and who is in it, e.g. waist-up two-shot",
             "beats": "3 to 6 short beat phrases in time order, comma-separated, e.g. side step to the left, wave \
            toward the camera, clockwise full-body turn, hands raised overhead, final front-facing pose",
             "timed": "the same beats with their times, e.g. 0-2.5s side step to the left; 2.5s clockwise turn",
             "scene": "everything in the frame besides the performer that stays as filmed, the other people first, by \
            look and place, e.g. the woman on the left in a yellow raincoat, a wooden bench, a brick wall",
             "props": "what the performer holds or uses that stays, with how, e.g. the umbrella she holds over her \
            head, the ball at his feet; never clothes or accessories they wear, nor what hangs or stands apart from them; \
            empty when none",
             "text": "the on-screen captions or graphics, quoted, e.g. \"Day 1\", \"Follow\"; empty when none",
             "feet": "yes if the performer's feet are on the ground in the frame for most of the clip, else no"\(gaze)}
            """
    }

    /// The prompt that splits the person's own request (`text`) into the parts of the service prompt: `people`
    /// characters at `@Image1…`, the new place at `@Image<place>` when there is one. Text only, no images.
    public static func wish(_ text: String, people: Int, place: Int?) -> String {
        let images = people == 1 ? "@Image1 is the character" : "@Image1 to @Image\(people) are the characters"
        let location = place.map { " @Image\($0) is the new place that replaces the video's background." } ?? ""
        return """
            A person wrote this request for a video edit. @Video1 is the source video; \(images) that replace its \
            people, in that order.\(location)
            Request:
            \"\"\"
            \(text)
            \"\"\"
            Split the request into the parts of a prompt. The request may be in any language: write every part in \
            English, translated faithfully, with all of the person's details; never add anything they did not say. \
            Write the words they use for things, never an @Image or @Video name in their place. Leave out only what \
            asks to swap the people for the images, to put them in the new place, or to keep the camera, the timing, \
            the moves or the look as in the images, since the prompt says that already; keep every detail they add \
            to it, and each thing of the setting they name to keep goes in kept_setting. Put each detail in one part only: what is in looks, \
            moving, kept, place, light, kept_setting, beats or camera is not repeated in notes.
            For example, "swap the boy in @Video1 for the robot from @Image1: silver body, red cape. it does \
            the same moves, a kickflip then a wave, and keeps his skateboard. put it in the snowy forest @Image2 \
            instead of the parking lot, make it dusk" is
            {"characters": [{"performer": "the boy", "noun": "robot", "pronoun": "its", "looks": "silver body, red cape", \
            "moving": "", "kept": ["his skateboard"], "notes": []}], \
            "place": "snowy forest", "place_noun": "forest", "replaced": "the parking lot", \
            "beats": "a kickflip, then a wave", "camera": "", "light": "dusk light", "kept_setting": [], "notes": []}
            And "replace the woman in @Video1 with the girl in @Image1, keep the bench, the brick wall and the camera \
            as they are" is
            {"characters": [{"performer": "the woman", "noun": "girl", "pronoun": "", "looks": "", "moving": "", \
            "kept": [], "notes": []}], "place": "", "place_noun": "", "replaced": "", "beats": "", "camera": "", \
            "light": "", "kept_setting": ["the bench", "the brick wall"], "notes": []}
            Reply with one JSON object and nothing else:
            {"characters": [one object per character, in image order:
              {"performer": "who in @Video1 they say is replaced, as a noun phrase with every detail they give of \
            them (what they wear, where they are, what they do), e.g. the man in the red cap dancing on the left; \
            empty if they don't say",
               "noun": "one word for what they call the character, e.g. man, girl, robot; empty if not said",
               "pronoun": "her, his, its or their, as they refer to it; empty if not said",
               "looks": "what they say the character looks like and wears",
               "moving": "only the parts they say swing or flow, e.g. hair and scarf; empty if not said",
               "kept": ["each object or accessory they say the character keeps from the video"],
               "notes": ["each other thing they say about the character, as a sentence: what it holds or feels; never \
            its moves or actions, which go in beats"]}],
             "place": "what they say the new place looks like",
             "place_noun": "one word for what they call the new place, e.g. garden; empty if not said",
             "replaced": "what they say the new place replaces",
             "beats": "every move or action they say the performer does, in their order, e.g. walks to the door, \
            waves; empty if they say none",
             "camera": "the camera they describe",
             "light": "the light or time of day they ask for, e.g. warm lamplight; empty if not said",
             "kept_setting": ["each thing of the video's setting they name to keep as filmed, in their words, e.g. \
            the brick wall; never the camera, the cuts or the people"],
             "notes": ["each other thing they ask for, as a sentence"]}
            """
    }
}
