# Lexer flow

This document walks through how `src/lexer/init.luau` turns Luau source into a token stream. It covers the scanning flow, the state the scanner carries, and where the behavior deliberately differs from Luau's own lexer in `Ast/src/Lexer.cpp`.

## The contract

`Lexer.scan(source)` returns an iterator typed `() -> (TokenName?, string)`. Each call produces the next token's kind and content, and once the source is exhausted every call returns `nil, ""`. The kinds the scanner emits are `iden`, `keyword`, `builtin`, `type`, `string`, `number`, `comment`, and `operator`. The `background` and `custom` kinds exist in the public `TokenName` type for theming but never come out of the scanner.

Two invariants matter to consumers. Token contents concatenate back to the exact source, so a consumer can walk token lengths to compute positions. Whitespace never gets its own token, since a whitespace run appends to the content of the token before it and whitespace before the first token becomes a prefix of that first token.

`scan` also accepts an optional `startIndex` that begins scanning at that byte with fresh context. Tokens whose meaning depends on what came earlier, like type positions or interpolation holes, may classify differently in a partial scan than they would in a full one.

`Lexer.scanEach(source, onToken)` walks the same scanner but delivers every token through a direct callback instead of an iterator, which skips a coroutine round trip per token. The rich text builder reads whole sources, so it uses this form whenever a lexer provides it.

## How a scan runs

`Lexer.scan` wraps `scanSource` in a coroutine and hands `coroutine.yield` in as the emit callback, so tokens stream out lazily as the consumer pulls them. All scanner state lives in locals inside `scanSource`, which keeps concurrent scans of different sources fully independent.

`scanSource` is one loop over byte positions. Each iteration reads the byte at the current index and dispatches on it, checking in this order. Whitespace merges into the previous token. An identifier start byte goes to `scanIden`. A digit, or a dot followed by a digit, goes to `scanNumber`. Two dashes go to `scanComment`. A quote or apostrophe goes to `scanQuoted`. A backtick starts an interpolated string. A closing brace whose depth matches the top of the interpolation hole stack resumes the surrounding interpolated string. An opening bracket that forms a long bracket opener goes to `scanLongBracket` as a string. An at sign goes to `scanAttribute`. Everything else goes to `scanOperator`.

## Whitespace merging

The scanner cannot yield a token the moment it ends, because whitespace after it still needs to join its content. So `emit` queues each token, and the queued token only flushes when the next one arrives. When the loop hits whitespace it calls `emitSuffix`, which appends the run to the queued token, or stores it in `pendingPrefix` when nothing is queued yet. `pendingPrefix` then rides along on the front of the next emitted token. A source containing only whitespace never emits a real token, so the leftover prefix flushes as a single `iden` token to keep coverage exact.

## Identifiers

`scanIden` reads an identifier and classifies it. Keyword lookups come first. Inside a type context most keywords end the context, since something like `then` or `end` means the annotation is over, while `nil`, `true`, `false`, and `typeof` stay legal inside type expressions. A `type` keyword at statement level only arms the alias machinery when `isAliasHead` confirms that a name, an optional generic parameter list, and an equals sign follow, so calling a variable named `type` still lexes as plain code.

When the scanner is in a type context, any identifier that is not a keyword emits as a `type` token, unless the context is suspended inside `typeof(...)`, which takes a value expression.

Outside type contexts the word tables in `language.luau` decide. Global builtins like `print` emit as `builtin`. A library member like the `floor` in `math.floor` also emits as `builtin`, using the last three emitted token texts as context. The member must sit directly after a dot, the token before the dot must be a known library, and the token before that must not itself end in a dot, which keeps `foo.math.floor` from counting. Everything else is an `iden`.

## Numbers

`scanNumber` mirrors the upstream lexer's greedy skip. It takes digits, dots, and underscores, then an `e` or `E` with an optional sign, then any trailing run of alphanumerics and underscores. The trailing run is what keeps `0xFF_AA` and `0b1010` whole, and it also means malformed literals like `1.2.3` or `3px` lex as a single `number` token, matching how Luau reports them as one bad literal.

## Strings and escapes

`scanQuoted` walks a single or double quoted string byte by byte. A backslash defers to `skipEscape`, which mirrors upstream's `readBackslashInString`. An escaped carriage return also consumes the line feed after it, and `\z` swallows all following whitespace including line breaks, which is how a quoted string legally continues onto the next line. Any other escape just skips the escaped byte, so an escaped quote stays inside the string and an escaped backslash before the closing quote still closes it. An unfinished string terminates at a bare newline or carriage return so the code below keeps highlighting normally while someone is mid-keystroke.

Long bracket strings and comments share `scanLongBracket`. `matchLongOpen` counts the equals signs in the opener, and the scanner then searches for the matching closer with a plain `string.find` on the literal closer text. That lands on the same byte upstream's exact level matching does. An unfinished long bracket runs to the end of the source.

Interpolated strings are the one place string scanning hands control back to plain code. `scanInterpPiece` reads string text from the opening backtick until it hits one of three things. A closing backtick, bare line break, or end of source ends the string. An opening brace ends the piece as a hole, and the main loop pushes the current bracket depth onto `holeStack`. Ordinary escapes defer to `skipEscape`, with one special case checked first. The brace in a `\u{2603}` escape belongs to the string text, so the scanner skips `\u{` outright rather than letting it open a hole. While a hole is open the main loop lexes normally, and a closing brace at the recorded depth pops the stack and resumes `scanInterpPiece` for the next string piece. The depth check is what lets table literals and nested braces live inside a hole without ending it early.

## Comments

`scanComment` handles both forms. A long bracket opener after the two dashes scans like a long string but emits as `comment`. Otherwise the comment runs through its newline, and that newline is part of the token's content so the stream still covers every byte. Hot comments like `--!strict` are ordinary comments here, since upstream also lexes them as comments and leaves extraction to the parser.

## Attributes

An at sign followed by an identifier start lexes as one token, so `@native` matches upstream's single `Attribute` lexeme. It emits as `keyword`, which is the closest of the public token kinds. A bare at sign, including the one opening an `@[...]` attribute list, emits as a lone `operator`.

## Operators

`scanOperator` tries three character lexemes first, then two, then one, against the sets in `constants.luau`. A byte that belongs to no operator emits as a single character `iden` so coverage never breaks on unexpected input. Every matched operator then passes through `handleOperator`, which applies its side effects. Parens, braces, and brackets adjust the bracket depth. The `::`, `->`, and annotation colon operators enter the type context. Equals signs, commas, semicolons, and closing brackets exit it at the appropriate depths. Angle brackets track generic argument nesting while a type context is active.

## The type context machine

Luau only distinguishes type positions in the parser, so the scanner approximates them with a small state machine whose flags live as hot locals inside `scanSource`.

`typeMode` says identifiers currently lex as `type` tokens, and `typeEntryDepth` records the bracket depth where the context began so the context ends when its enclosing bracket closes. `typeAngle` counts generic angle brackets so the `>` in `Array<number>` does not read as an exit. `typeofArmed` and `typeofDepth` implement the `typeof(...)` suspension, arming on the keyword and suspending type classification until its paren closes. `aliasNamePending` and `aliasAwaitEquals` carry a `type Name = ...` statement across its pieces, coloring the alias name as a type and keeping the context alive through the equals sign. `typeContinues` marks tokens like a trailing union bar that promise the annotation continues, which lets `checkTypeNewline` keep the context across a wrapped line while still ending it at an ordinary line break.

Entries come from three places. A `::` cast always enters. A `->` arrow enters when the scanner is not already in a context, so a return type stays colored even where the surrounding context already ended. A colon enters only when `isAnnotationColon` decides it starts an annotation rather than a method access, by peeking ahead without consuming anything. A colon followed directly by a paren or brace reads as an annotation, since those open function and table types. Otherwise the scanner reads the dotted identifier chain after the colon. Call arguments right after the chain mean a method access, anything else means an annotation, and no identifier chain at all means no annotation.

This machine is intentionally not extracted from `scanSource`. Its flags are closure locals shared by the scan functions, and moving them into a state table would add per-token hash lookups to the hot path.

## Deviations from Luau's lexer

The scanner mirrors upstream wherever tokenization differs visibly, and the test suite pins those behaviors. The remaining differences are deliberate choices for a highlighter.

Upstream has broken token kinds for unfinished strings, comments, and bad unicode, and this scanner has no error kinds at all. Broken constructs get their nearest ordinary color, which reads better while someone is typing. Bytes at 128 and above lex as identifier characters instead of upstream's `BrokenUnicode`, so non-ASCII text renders in the identifier color. Whitespace and comment newlines merge into token contents to satisfy the coverage contract, while upstream tokens exclude surrounding trivia. The contextual words `continue`, `export`, and `self` sit in the keyword table unconditionally, matching how the Studio editor colors them, where upstream leaves them to the parser. The `@[` opener of an attribute list stays a lone `@` operator rather than upstream's dedicated `AttributeOpen` lexeme, which renders identically. Generic parameter lists in declarations like `function f<T>()` are not type colored, because `<` is ambiguous with less than at lex time and a wrong guess would mishighlight comparisons, which are far more common.

## The navigator

`Lexer.navigator()` builds the token navigator from `navigator.luau`, which wraps a scan in a coroutine and caches every token it pulls. `Next` advances through the cache or resumes the scan, and `Peek` reads ahead of or behind the current position without moving it, using negative offsets for already read tokens. `SetSource` clears the cache and restarts the scan from the beginning.

`HotswapSource` replaces the source while keeping every cached token the edit provably left untouched. Like `SetSource`, it resets the read position, so the next `Next` returns the first token of the new source even when that token came from the cache. The scanner reports a restart snapshot alongside each token that ends somewhere safe to resume, meaning no type context is open, no interpolation hole is pending, and the alias and typeof machinery is idle. Each snapshot carries the bracket depth at that point and a watermark recording the furthest byte the scan had read by then, lookahead included. On a hotswap the navigator measures the shared byte prefix of the old and new sources and walks back to the latest snapshot whose watermark sits inside it. Everything the scanner read to produce those tokens and reach that state is identical in both sources, so the kept tokens and the resumed scan match a full scan of the new source exactly. The resumed scan seeds its bracket depth from the snapshot and its previous token texts from the cache, which keeps the library member heuristic working across the seam. When no snapshot qualifies, the navigator falls back to a full rescan.
