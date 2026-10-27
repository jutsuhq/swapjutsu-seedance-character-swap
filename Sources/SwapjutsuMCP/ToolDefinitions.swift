import ComfyKit
import SwapjutsuAgent

/// What `tools/list` shows of each tool: its name, what it does, its input schema and hints.
extension Tool {
    var definition: JSONValue {
        var definition: JSONValue = ["name": .string(rawValue), "title": .string(title), "description": .string(about)]
        definition["inputSchema"] = [
            "type": "object", "properties": .object(properties), "additionalProperties": false,
        ]
        if !required.isEmpty { definition["inputSchema"]?["required"] = .array(required.map { .string($0) }) }
        definition["annotations"] = annotations
        return definition
    }

    private var title: String {
        switch self {
        case .capabilities: "Swapjutsu capabilities"
        case .show: "Show an Swapjutsu page"
        case .prepare: "Prepare clips"
        case .clips: "Clips and their prep"
        case .setCharacters: "Set a clip's characters"
        case .prepareAgain: "Prepare a clip again"
        case .correctTarget: "Correct who is replaced on a frame"
        case .quote: "What a render costs"
        case .render: "Render a clip (paid)"
        case .finalize: "Finalize a draft at 1080p (paid)"
        case .jobAction: "Cancel or retry a render or prep"
        case .librarySearch: "Search the Library"
        case .frames: "Check a render's frames"
        }
    }

    private var about: String {
        switch self {
        case .capabilities:
            """
            What the Swapjutsu app is and can do now: its version (and the helper's, with helperNote when the \
            helper is older and the MCP server must be reconnected), whether a Comfy API key is saved (Seedance \
            renders need one; the key itself never leaves the app), whether the person's own ComfyUI is set up \
            and passed its Check (hasOwnComfyUI: render takes model wan22Animate) and the state of the depth model prep uses.
            """
        case .show:
            """
            Opens a page of the Swapjutsu app and brings its window to the front: a sidebar page (screen), a clip \
            in Create (clip), or a result's page in Library (result, a render id; a render that isn't finished \
            opens on its clip in Create). Give exactly one.
            """
        case .prepare:
            """
            Prepares a video for a character swap, free and on this Mac: one clip per range, each 4–30 s. Returns \
            the clips at once, waiting for prep; follow them with clips. Calling again with the same request_id \
            returns the same clips, also after a relaunch; the same request_id with other parameters is refused \
            (request_conflict).
            """
        case .clips:
            """
            One clip, or every clip: prep's stage and progress, the people prep found (each with an id, a face \
            crop and their share of the screen) and who is replaced, warnings, and the paths of control.mp4 (what \
            Seedance gets) and review.mp4 (who was found and the masks). wait_seconds waits for prep to stop, up \
            to 60 s; running out of time cancels nothing.
            """
        case .setCharacters:
            """
            Puts the image that replaces each person on a prepared clip (person ids from clips, in any order; an \
            image for someone who has one replaces theirs, and view adds another look of the same character), and \
            sets the background removal and the prompt. Starts no render and spends nothing.
            """
        case .prepareAgain:
            """
            Runs prep on a clip again, free, with another target, lip-sync guide or control; renders already made \
            stay. \
            Refused (busy) while its prep or a render is on its way.
            """
        case .correctTarget:
            """
            Fixes who is replaced on one frame of a prepared clip, free and on this Mac: a click on the person \
            (x, y in pixels of control.mp4 from the top left) or a mask image of them (white = the person). The \
            app opens the clip, re-tracks that shot both ways from the frame in seconds and shows the frame before \
            and after; clips shows where it is (fix). prepare_again then applies it to control.mp4, and every later \
            prep of the clip keeps it. Best on a frame from the clip's flags, where the mask is wrong.
            """
        case .quote:
            """
            Estimates what a Seedance render of a clip costs, in USD: a range from Comfy's bill for drafts and its price badge for finals \
            (isEstimate). high is what max_cost and the daily agent budget are checked against; budget says how \
            much of today's agent budget is left. model wan30 quotes Wan 3.0 on Comfy, billed for the clip's \
            seconds twice (the control video it reads and the render). model wan22Animate quotes $0: it runs on \
            the person's own ComfyUI. Free.
            """
        case .render:
            """
            Renders a prepared clip with every replaced person's character set, on Seedance, paid from the \
            person's Comfy credits: draft (480p, about 2 min, finalizable within 7 days), final720 or final1080. \
            It is sent only if the top of the estimate (quote's high) is within max_cost and within what is left \
            of the person's daily agent budget (Settings › Agents, $0 unless they set one). Otherwise the render \
            is made but waits in Jobs (stage waiting, detail says why) until the person sends it; one held only \
            over max_cost is sent when the same request_id and parameters come again with a max_cost that covers \
            it and still fits the budget. One render at a time per clip. The same request_id returns the same render, also after a relaunch: repeat it to see \
            where the render is. Results land in Library; clips lists every render. model wan30 renders with \
            Wan 3.0 on Comfy instead, final480, final720 or final1080, clips of up to 15 s, no draft, under the \
            same max_cost and budget checks. model wan22Animate renders \
            with Wan 2.2 Animate (open source) on the person's own ComfyUI instead, final480 or final720, for $0, \
            so it is always within max_cost and the budget; it replaces one person, so the clip must be prepared \
            with one target and its original background, and capabilities' hasOwnComfyUI must be true.
            """
        case .finalize:
            """
            Renders a finished draft at 1080p from its Seedance task, with the same motion; only possible within 7 \
            days of the draft (finalizableUntil). Paid, and checked like render: within max_cost and the day's \
            agent budget, or it waits for the person. The same request_id returns the same final; with a higher \
            max_cost it sends a final held over the old one.
            """
        case .jobAction:
            """
            cancel stops a render (on Comfy Cloud too; a direct Seedance task can't be canceled, keeps running and \
            may be charged, so it keeps its request) or a clip's prep; retry picks a stopped render up again: free \
            when it has a Comfy request, otherwise a new paid send checked like render (a render waiting for the \
            person is sent if it now fits). A render whose send may have reached Comfy (stage unknown) or one the \
            person started is theirs to retry (needs_person). retry on a failed or canceled clip prepares it again. \
            Nothing is deleted.
            """
        case .librarySearch:
            """
            Finished drafts and finals in the Library, newest first: each with its render id, clip id, title, \
            version name, quality, the path of the video (with the clip's own soundtrack, in ~/Movies/Swapjutsu), \
            when it was sent and finished, the clip's length in seconds and its prompt (cut to 200 characters; \
            promptTruncated says so). text keeps the results whose title, version name or prompt contain every \
            word of it; quality keeps one quality. limit results a page (default 20, up to 50); pass nextCursor \
            as cursor for the next page. Free.
            """
        case .frames:
            """
            Checks a finished render: writes the same moments of the clip as it was, control.mp4 (what the \
            generator read) and the render, each as a JPEG, and one contact sheet with a row per moment and those \
            three columns. seconds picks the moments (up to 12, within the clip); otherwise count of them (4 by \
            default) spread evenly. Each call writes a new folder in the clip's folder. Free; look at the sheet \
            instead of grabbing frames yourself.
            """
        }
    }

    private static let target: JSONValue = [
        "description": "Who is replaced: main (the person most on screen), all, or person ids from clips.",
        "anyOf": [
            ["type": "string", "enum": ["main", "all"]],
            ["type": "array", "items": ["type": "integer", "minimum": 1], "minItems": 1],
        ],
    ]

    private static let faceGuide: JSONValue = [
        "type": "boolean",
        "description":
            "Draws face landmarks over the depth where the face is large enough, to guide lip sync. Seedance may draw the lines into the face.",
    ]

    private static let control: JSONValue = [
        "type": "string", "enum": .array(AgentControl.allCases.map { .string($0.rawValue) }),
        "description": """
        What paints the replaced people in control.mp4. depth (the default): colored depth. hybrid-hands: \
        colored depth with their real hands from the footage, tracked through each shot, for exact hands and \
        fingers. hybrid-body: the real person but for the head, which stays colored depth, for the exact pose; \
        the source's clothes may show through. The prompt tells Seedance the footage is motion only and the \
        face and outfit come from the character image.
        """,
    ]

    private static let clip: JSONValue = ["type": "string", "description": "A clip id from prepare or clips."]

    private static let quality: JSONValue = [
        "type": "string", "enum": .array(AgentQuality.allCases.map { .string($0.rawValue) }),
        "description": .string(
            "Seedance: draft (480p), final720 or final1080. Wan 3.0: final480, final720 or final1080. Wan 2.2 "
                + "Animate: final480 or final720."),
    ]

    private static let model: JSONValue = [
        "type": "string", "enum": .array(AgentModel.allCases.map { .string($0.rawValue) }),
        "description":
            .string(
                "seedance25 (paid, on Comfy; the default), wan30 (paid, on Comfy, up to 15 s) or wan22Animate (open "
                    + "source, on the person's own ComfyUI, $0)."),
    ]

    private static let requestID: JSONValue = [
        "type": "string", "pattern": "^[A-Za-z0-9_-][A-Za-z0-9._-]{0,63}$",
        "description": "Your id for this request; repeat it to retry safely or to see where it is.",
    ]

    private static let maxCost: JSONValue = [
        "type": "number", "minimum": 0,
        "description": .string(
            "USD: the most this render may cost, compared with the top of quote's estimate. Raise it on the same "
                + "request_id to send a render held over it."),
    ]

    private var properties: [String: JSONValue] {
        switch self {
        case .capabilities: [:]
        case .show:
            [
                "screen": [
                    "type": "string", "enum": .array(AgentScreen.allCases.map { .string($0.rawValue) }),
                    "description": "The sidebar page: Create, Jobs, Library or Settings.",
                ],
                "clip": ["type": "string", "description": "A clip id from prepare or clips: opens it in Create."],
                "result": [
                    "type": "string",
                    "description": "A render id from library_search, render or clips: opens its page in Library.",
                ],
            ]
        case .prepare:
            [
                "video": ["type": "string", "description": "The video file on this Mac."],
                "request_id": [
                    "type": "string", "pattern": "^[A-Za-z0-9_-][A-Za-z0-9._-]{0,63}$",
                    "description": "Your id for this request; repeat it to retry safely.",
                ],
                "ranges": [
                    "type": "array", "minItems": 1,
                    "description": """
                    Parts of the video in seconds, in order and apart, each 4–30 s long. Without it: the whole \
                    video, or its first 30 s.
                    """,
                    "items": [
                        "type": "object", "required": ["start", "end"], "additionalProperties": false,
                        "properties": ["start": ["type": "number", "minimum": 0], "end": ["type": "number"]],
                    ],
                ],
                "target": Self.target,
                "face_guide": Self.faceGuide,
                "control": Self.control,
            ]
        case .clips:
            [
                "clip": ["type": "string", "description": "A clip id; without it, every clip."],
                "wait_seconds": [
                    "type": "number", "minimum": 0, "maximum": .number(ClipsCommand.maxWait),
                    "description": "Wait up to this long for prep to stop.",
                ],
            ]
        case .setCharacters:
            [
                "clip": Self.clip,
                "characters": [
                    "type": "array",
                    "items": [
                        "type": "object", "required": ["person", "image"], "additionalProperties": false,
                        "properties": [
                            "person": ["type": "integer", "minimum": 1, "description": "A replaced person's id."],
                            "image": [
                                "type": "string",
                                "description": "An image file on this Mac, at least 300 px a side, sides within 1:2.5.",
                            ],
                            "view": [
                                "type": "boolean",
                                "description":
                                    "Another view of this person's character (side, back, full body), not a new one.",
                            ],
                        ],
                    ],
                ],
                "remove_background": [
                    "type": "boolean", "description": "Characters go to Seedance cut out onto grey.",
                ],
                "prompt": ["type": "string", "description": "Wishes added after the prompt prep writes."],
            ]
        case .prepareAgain:
            ["clip": Self.clip, "target": Self.target, "face_guide": Self.faceGuide, "control": Self.control]
        case .correctTarget:
            [
                "clip": Self.clip,
                "person": [
                    "type": "integer", "minimum": 1, "description": "A replaced person's id; the first when left out.",
                ],
                "frame": ["type": "integer", "minimum": 0, "description": "The frame of control.mp4, from 0."],
                "x": ["type": "number", "minimum": 0, "description": "The click, pixels from the left."],
                "y": ["type": "number", "minimum": 0, "description": "The click, pixels from the top."],
                "mask": [
                    "type": "string",
                    "description":
                        "Instead of a click: a PNG or JPEG of the frame's mask on this Mac, white = the person.",
                ],
            ]
        case .quote: ["clip": Self.clip, "quality": Self.quality, "model": Self.model]
        case .render:
            [
                "clip": Self.clip, "quality": Self.quality, "request_id": Self.requestID, "max_cost": Self.maxCost,
                "model": Self.model,
            ]
        case .finalize:
            [
                "render": ["type": "string", "description": "A finished draft's render id, from render or clips."],
                "request_id": Self.requestID, "max_cost": Self.maxCost,
            ]
        case .jobAction:
            [
                "job": ["type": "string", "description": "A render id, or a clip id for its prep."],
                "action": [
                    "type": "string", "enum": .array(AgentJobAction.allCases.map { .string($0.rawValue) }),
                    "description": "cancel or retry.",
                ],
            ]
        case .librarySearch:
            [
                "text": [
                    "type": "string", "description": "Words that must all appear in the title, version name or prompt.",
                ],
                "quality": Self.quality,
                "limit": [
                    "type": "integer", "minimum": 1, "maximum": .number(Double(LibrarySearchCommand.maxLimit)),
                    "description": "Results a page; 20 when left out.",
                ],
                "cursor": ["type": "string", "description": "nextCursor from the page before."],
            ]
        case .frames:
            [
                "render": ["type": "string", "description": "A finished render's id, from render, clips or library_search."],
                "seconds": [
                    "type": "array", "minItems": 1, "maxItems": .number(Double(FramesCommand.maxCount)),
                    "items": ["type": "number", "minimum": 0], "description": "Moments of the clip, in seconds.",
                ],
                "count": [
                    "type": "integer", "minimum": 1, "maximum": .number(Double(FramesCommand.maxCount)),
                    "description": "Moments spread evenly when seconds is left out; 4 by default.",
                ],
            ]
        }
    }

    private var required: [String] {
        switch self {
        case .capabilities, .clips, .show, .librarySearch: []
        case .prepare: ["video", "request_id"]
        case .setCharacters, .prepareAgain: ["clip"]
        case .quote: ["clip", "quality"]
        case .correctTarget: ["clip", "frame"]
        case .render: ["clip", "quality", "request_id", "max_cost"]
        case .finalize: ["render", "request_id", "max_cost"]
        case .frames: ["render"]
        case .jobAction: ["job", "action"]
        }
    }

    private var annotations: JSONValue {
        switch self {
        case .capabilities, .clips, .quote, .librarySearch: ["readOnlyHint": true, "openWorldHint": false]
        case .show: ["readOnlyHint": false, "destructiveHint": false, "openWorldHint": false]
        case .prepare, .setCharacters:
            ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false]
        case .prepareAgain, .correctTarget, .frames:
            ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false]
        // They reach Seedance on Comfy and spend the person's credits, or the person's own ComfyUI.
        case .render, .finalize:
            ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": true]
        case .jobAction:
            ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": true]
        }
    }
}
