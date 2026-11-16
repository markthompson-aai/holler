import Testing

@testable import HollerCore

@Suite struct RedactionTests {
  static let assemblyAIKey = "3f2a9c8e1b7d4e6f0a1b2c3d4e5f6a7b"

  @Test func assemblyAIKeyStandingAloneIsRedacted() {
    #expect(Redaction.redact("key \(Self.assemblyAIKey) saved") == "key [redacted key] saved")
    #expect(Redaction.redact("\(Self.assemblyAIKey)") == "[redacted key]")
    #expect(Redaction.redact("(\(Self.assemblyAIKey))") == "([redacted key])")
    #expect(Redaction.redact("\(Self.assemblyAIKey).txt") == "[redacted key].txt")
    #expect(Redaction.redact("x\(Self.assemblyAIKey)") == "x\(Self.assemblyAIKey)")
  }

  @Test func openAIAndAnthropicKeysAreRedacted() {
    #expect(
      Redaction.redact("using sk-proj-AbCdEfGhIjKlMnOpQrStUvWxYz0123456789 now")
        == "using [redacted key] now")
    #expect(
      Redaction.redact("sk-ant-api03-AbCdEfGhIjKlMnOpQrStUvWxYz0123456789-AbCdEfGhIjKlMnOpQrStUvWxYzAA")
        == "[redacted key]")
    #expect(Redaction.redact("task-runner sk-1 disk-usage") == "task-runner sk-1 disk-usage")
  }

  @Test func gitHubTokensAreRedacted() {
    #expect(
      Redaction.redact("remote: https://ghp_AbCdEfGhIjKlMnOpQrStUvWxYz0123456789@github.com/x/y")
        == "remote: https://[redacted token]@github.com/x/y")
    #expect(
      Redaction.redact("github_pat_11ABCDEFG0abcdefghijklmnop_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuv")
        == "[redacted token]")
  }

  @Test func awsAccessKeyIdsAreRedacted() {
    #expect(Redaction.redact("aws_access_key_id AKIAIOSFODNN7EXAMPLE") == "aws_access_key_id [redacted key]")
    #expect(Redaction.redact("AKIA1234") == "AKIA1234")
  }

  @Test func slackTokensAreRedacted() {
    #expect(
      Redaction.redact("xoxb-1234567890-1234567890123-AbCdEfGhIjKlMnOpQrStUvWx") == "[redacted token]")
    #expect(Redaction.redact("xoxp-12-34") == "xoxp-12-34")
  }

  @Test func jwtsAreRedacted() {
    let jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
    #expect(Redaction.redact("got \(jwt) back") == "got [redacted token] back")
    #expect(Redaction.redact("token: \(jwt)") == "token: [redacted value]")
  }

  @Test func aLongUnbrokenLineRedactsInWellUnderASecond() {
    // An unwrapped read can carry a 40,000-character line, such as a base64
    // dump; an unbounded URL scheme backtracked from every character of it.
    let blob = String(repeating: "z", count: 40_000)
    let start = ContinuousClock.now
    #expect(Redaction.redact(blob) == blob)
    #expect(ContinuousClock.now - start < .seconds(1))
  }

  @Test func aLongRunOfDottedWordsRedactsInWellUnderASecond() {
    // Every dot starts a word that might be a secret's name; unbounded, the
    // name pattern ran to the end of the line from each one.
    let run = String(repeating: "a.b-c_", count: 2_000) + "api_key=abcdefgh12345678"
    let start = ContinuousClock.now
    #expect(Redaction.redact(run).hasSuffix("api_key=[redacted value]"))
    #expect(ContinuousClock.now - start < .seconds(1))
  }

  @Test func bearerHeadersAreRedacted() {
    #expect(
      Redaction.redact("Authorization: Bearer AbCdEf0123456789.xyz") == "Authorization: Bearer [redacted token]")
    #expect(Redaction.redact("-H 'authorization: bearer abcdefgh12'") == "-H 'authorization: bearer [redacted token]'")
    #expect(Redaction.redact("the Bearer of bad news") == "the Bearer of bad news")
  }

  @Test func keyValuePairsWithSecretNamesAreRedacted() {
    #expect(Redaction.redact("export OPENAI_API_KEY=sk-live-abcdefghijklmnop") == "export OPENAI_API_KEY=[redacted value]")
    #expect(Redaction.redact("DB_PASSWORD: hunter2hunter2") == "DB_PASSWORD: [redacted value]")
    #expect(Redaction.redact("client_secret = \"abcdefgh\"") == "client_secret = \"[redacted value]\"")
    #expect(Redaction.redact("  \"accessToken\": \"abcdefghij\",") == "  \"accessToken\": \"[redacted value]\",")
    #expect(Redaction.redact("GITHUB_TOKEN='abcdefghij'") == "GITHUB_TOKEN='[redacted value]'")
  }

  @Test func shortValuesAndOtherNamesAreKept() {
    #expect(Redaction.redact("DEBUG_KEY=1") == "DEBUG_KEY=1")
    #expect(Redaction.redact("password: (none)") == "password: (none)")
    #expect(Redaction.redact("input_tokens: 1234") == "input_tokens: 1234")
    #expect(Redaction.redact("PATH=/usr/local/bin:/usr/bin") == "PATH=/usr/local/bin:/usr/bin")
    #expect(Redaction.redact("Press any key: continue please") == "Press any key: continue please")
    #expect(Redaction.redact("primary key: created_at_index") == "primary key: created_at_index")
    #expect(Redaction.redact("API_TOKEN=abc1234") == "API_TOKEN=abc1234")
  }

  @Test func tokenSecretAndPasswordAreNamesOnTheirOwn() {
    #expect(Redaction.redact("password: hunter2hunter2") == "password: [redacted value]")
    #expect(Redaction.redact("PASSWORD=hunter2hunter2") == "PASSWORD=[redacted value]")
    #expect(Redaction.redact("token: abcdefgh12345678") == "token: [redacted value]")
    #expect(Redaction.redact("secret = \"abcdefgh\"") == "secret = \"[redacted value]\"")
    #expect(Redaction.redact("passwd=abcdefgh1") == "passwd=[redacted value]")
  }

  @Test func aPasswordCanBeShort() {
    #expect(Redaction.redact("PASSWORD=short1") == "PASSWORD=[redacted value]")
    #expect(Redaction.redact("db_password: pw12") == "db_password: [redacted value]")
    for placeholder in ["none", "null", "true", "****", "(none)", "abc"] {
      #expect(Redaction.redact("password: \(placeholder)") == "password: \(placeholder)")
    }
  }

  @Test func aQuotedValueMayHaveSpacesInIt() {
    #expect(
      Redaction.redact("password: \"correct horse battery staple\"") == "password: \"[redacted value]\"")
    #expect(Redaction.redact("client_secret: 'abc def ghi jkl'") == "client_secret: '[redacted value]'")
    #expect(Redaction.redact("\"apiKey\": \"abc def\", \"name\": \"web app\"") == "\"apiKey\": \"abc def\", \"name\": \"web app\"")
    // A quote left open doesn't swallow the lines after it.
    #expect(Redaction.redact("api_key = \"abc\nnext line here\"") == "api_key = \"abc\nnext line here\"")
  }

  @Test func stripeGoogleGitLabNpmAndHuggingFaceKeysAreRedacted() {
    #expect(Redaction.redact("stripe: sk_live_51Habcdefghijklmnopqrstuvwxyz0123") == "stripe: [redacted key]")
    #expect(Redaction.redact("rk_test_51Habcdefghijklmnopqrstuvwxyz0123") == "[redacted key]")
    #expect(Redaction.redact("google AIzaSyA1234567890abcdefghijklmnopqrstuv ok") == "google [redacted key] ok")
    #expect(Redaction.redact("gitlab glpat-abcdefghij0123456789") == "gitlab [redacted token]")
    #expect(Redaction.redact("npm_abcdefghijklmnopqrstuvwxyz0123456789") == "[redacted token]")
    #expect(Redaction.redact("hf_abcdefghijklmnopqrstuvwxyzABCDEFGH") == "[redacted token]")
    #expect(Redaction.redact("xapp-1-A0123456789-0123456789012-abcdef0123456789") == "[redacted token]")
    #expect(Redaction.redact("npm_config_user_agent hf_hub_download sk_live_ glpat-short") == "npm_config_user_agent hf_hub_download sk_live_ glpat-short")
  }

  @Test func anUppercaseHexKeyIsRedactedToo() {
    #expect(Redaction.redact("KEY 0123456789ABCDEF0123456789ABCDEF") == "KEY [redacted key]")
    #expect(Redaction.redact("0123456789ABCDEF0123456789ABCDEF0") == "0123456789ABCDEF0123456789ABCDEF0")
  }

  @Test func basicAuthHeadersAreRedacted() {
    #expect(
      Redaction.redact("Authorization: Basic YWRtaW46aHVudGVyMmh1bnRlcjI=") == "Authorization: Basic [redacted token]")
    #expect(Redaction.redact("-H \"authorization: basic YWRtaW46aHVudGVy\"") == "-H \"authorization: basic [redacted token]\"")
    #expect(Redaction.redact("basic authentication is switched on") == "basic authentication is switched on")
  }

  @Test func passwordsOnACommandLineAreRedacted() {
    #expect(
      Redaction.redact("curl -u admin:hunter2hunter2 https://example.com") == "curl -u admin:[redacted password] https://example.com")
    #expect(
      Redaction.redact("curl -s --user 'admin:pw' https://example.com") == "curl -s --user 'admin:[redacted password]' https://example.com")
    #expect(Redaction.redact("psql --password hunter2hunter2 app") == "psql --password [redacted value] app")
    #expect(Redaction.redact("deploy --api-key abc123def --region eu") == "deploy --api-key [redacted value] --region eu")
    #expect(Redaction.redact("mysql -u root -phunter2 app") == "mysql -u root -p[redacted password] app")
  }

  @Test func flagsThatOnlyMentionASecretAreKept() {
    let text = "run --token-file /etc/token --max-tokens 4000 --password --verbose; mysql -P 3306 --protocol tcp; curl -u"
    #expect(Redaction.redact(text) == text)
  }

  @Test func aJWTCutShortAfterItsSecondPartIsStillRedacted() {
    #expect(
      Redaction.redact("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6") == "[redacted token]")
    #expect(Redaction.redact("eyJhbGciOiJIUzI1NiJ9 alone") == "eyJhbGciOiJIUzI1NiJ9 alone")
  }

  // MARK: - Tokens that wrap onto the next row

  /// A 40-column screen: an agent's input box sets the width.
  static func screen(_ rows: String...) -> String {
    (rows + ["╭" + String(repeating: "─", count: 38) + "╮", "│ >" + String(repeating: " ", count: 36) + "│"]).joined(separator: "\n")
  }

  static let box = "\n╭" + String(repeating: "─", count: 38) + "╮\n│ >" + String(repeating: " ", count: 36) + "│"

  @Test func aSecretThatWrapsAtTheScreenEdgeLosesItsTailToo() {
    // 18 characters of name, 22 of value to the edge, the rest on the next row.
    let text = Self.screen("ANTHROPIC_API_KEY=sk-ant-api03-abcdefghi", "jklmnopqrstuvwxyz0123456789", "Done.")
    #expect(text.split(separator: "\n")[0].count == 40)
    #expect(Redaction.redact(text) == "ANTHROPIC_API_KEY=[redacted value]\n[redacted]\nDone." + Self.box)
  }

  @Test func aTokenLongerThanTwoRowsIsFollowedDown() {
    let text = Self.screen(
      "token: ghp_abcdefghijklmnopqrstuvwxyz012", "3456789abcdefghijklmnopqrstuvwxyz0123456", "789abcdefghij and then some words", "kept")
    #expect(text.split(separator: "\n").prefix(2).map(\.count) == [40, 40])
    #expect(
      Redaction.redact(text) == "token: [redacted value]\n[redacted]\n[redacted] and then some words\nkept" + Self.box)
  }

  @Test func aBearerJWTThatWrapsInItsPayloadIsRedactedOnBothRows() {
    let text = Self.screen("auth: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdW", "IiOiIxMjM0In0.SflKxwRJSMeKKF2QT4f next")
    #expect(text.split(separator: "\n")[0].count == 40)
    #expect(Redaction.redact(text) == "auth: Bearer [redacted token]\n[redacted] next" + Self.box)
  }

  @Test func aSecretThatEndsBeforeTheEdgeLeavesTheNextRowAlone() {
    let text = Self.screen("API_KEY=sk-ant-api03-abcdefghijklmnopq", "PORT=3000")
    #expect(Redaction.redact(text) == "API_KEY=[redacted value]\nPORT=3000" + Self.box)
  }

  @Test func theLongestLineOfAListIsNotAScreenEdge() {
    // No other row is as long, so nothing says the value wrapped.
    let text = "DEBUG=true\nOPENAI_API_KEY=sk-proj-abcdefghijklmnopqrstuvwxyz\nPORT=3000\nHOST=localhost"
    #expect(Redaction.redact(text) == "DEBUG=true\nOPENAI_API_KEY=[redacted value]\nPORT=3000\nHOST=localhost")
  }

  @Test func aRowThatOpensWithSomethingElseIsLeftAlone() {
    let text = Self.screen("ANTHROPIC_API_KEY=sk-ant-api03-abcdefghi", "  indented output", "(next)")
    #expect(Redaction.redact(text) == "ANTHROPIC_API_KEY=[redacted value]\n  indented output\n(next)" + Self.box)
  }

  @Test func wrappedRowsKeepTheirLineCount() {
    let text = Self.screen("ANTHROPIC_API_KEY=sk-ant-api03-abcdefghi", "jklmnopqrstuvwxyz0123456789", "")
    #expect(Redaction.redact(text).count(where: { $0 == "\n" }) == text.count(where: { $0 == "\n" }))
  }

  @Test func urlPasswordsAreRedacted() {
    // DATABASE_URL isn't a secret name, so the URL rule does the work and the host stays readable.
    #expect(
      Redaction.redact("DATABASE_URL=postgres://admin:s3cr3t-pw@db.example.com:5432/app")
        == "DATABASE_URL=postgres://admin:[redacted password]@db.example.com:5432/app")
    #expect(
      Redaction.redact("connecting to postgres://admin:s3cr3t-pw@db.example.com:5432/app")
        == "connecting to postgres://admin:[redacted password]@db.example.com:5432/app")
    #expect(Redaction.redact("https://github.com/x/y") == "https://github.com/x/y")
    #expect(Redaction.redact("https://user@github.com/x/y") == "https://user@github.com/x/y")
  }

  @Test func pemBlocksAreReplacedWhole() {
    let text = """
      writing key
      -----BEGIN RSA PRIVATE KEY-----
      MIIEowIBAAKCAQEA0Z3VS5JJcds3xfn/ygWyF8PbnGy0AH8m
      s7dD2B9K+Q4JzLq2W1q2v8l7Qd1k4Kx3n0ZLx1hA2Qd9K5+
      -----END RSA PRIVATE KEY-----
      done
      """
    #expect(Redaction.redact(text) == "writing key\n[redacted private key]\n\n\n\ndone")
  }

  @Test func pemBlockCutOffByTheScreenEdgeIsStillReplaced() {
    let text = "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAA\nAAAEbm9uZQAA"
    #expect(Redaction.redact(text) == "[redacted private key]\n\n")
  }

  @Test func ordinaryCodeAndOutputAreUntouched() {
    let text = """
      7e636e3 Remove the old per-kind action code
      commit 7e636e3f9a2b4c8d1e0f3a5b7c9d2e4f6a8b0c1d
      id 123e4567-e89b-12d3-a456-426614174000
      /Users/test/Projects/demo/Sources/App.swift:42
      ❯ swift test --filter Redaction
      [1/3] Compiling HollerCore Redaction.swift
      """
    #expect(Redaction.redact(text) == text)
  }

  @Test func lineCountIsPreserved() {
    let text = "a\nBearer abcdefghij\n-----BEGIN PRIVATE KEY-----\nabc\ndef\n-----END PRIVATE KEY-----\nz\n"
    #expect(Redaction.redact(text).count(where: { $0 == "\n" }) == text.count(where: { $0 == "\n" }))
  }
}
