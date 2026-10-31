import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum IntegrationCategory: String, CaseIterable, Sendable, Identifiable {
    case popular = "Popular"
    case apple = "Apple"
    case devCloud = "Dev & Cloud"
    case dataStorage = "Data & Files"
    case workDocs = "Work & Docs"
    case chatMeetings = "Chat & Meet"
    case searchMedia = "Search & Media"
    case businessAuto = "Business & Auto"

    public var id: String { rawValue }
}

public enum RESTAuthStyle: String, Codable, Sendable, Hashable {
    case none
    case bearer
    case header
    case queryParam
    case basicToken
    case telegramBotPath
}

public enum IntegrationConnectionMode: Sendable, Hashable {
    /// First-party or hosted Streamable HTTP MCP server (supports OAuth and/or Keychain Bearer/header token).
    case remoteMCP(url: String, supportsToken: Bool = true, authHeader: String? = nil, setupHint: String = "Sign in with OAuth or paste an access token in Keychain.")
    /// Zero-setup public integration — connects in 1 tap with no API key required.
    case publicZeroKey(providerKey: String)
    /// Direct HTTPS REST integration powered by a Keychain API key or OAuth token.
    case apiKeyREST(
        providerKey: String,
        baseURL: String,
        authStyle: RESTAuthStyle,
        authName: String = "Authorization",
        secretLabel: String = "API key or access token",
        extraFieldKey: String? = nil,
        extraFieldLabel: String? = nil,
        setupHint: String
    )
    /// Native iPhone integration (EventKit, Contacts, iCloud Drive, Mail/Messages/Notes compose).
    case appleNative(appleKey: String, platformNote: String? = nil)
    /// Runs via official MCP stdio package on your connected Linux computer (`mcp-maipa-g`) and in Autonomous jobs.
    case stdioPackage(
        packageName: String,
        registryType: String = "npm",
        secretEnvNames: [String] = [],
        plainEnvNames: [String] = [],
        setupHint: String
    )
    case customWebhook
    case customMCP
}

public struct IntegrationProviderSpec: Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var detail: String
    public var category: IntegrationCategory
    public var isPopular: Bool
    public var search: String
    public var aliases: [String]
    public var symbol: String
    public var assetName: String?
    public var mode: IntegrationConnectionMode

    public init(
        id: String,
        name: String,
        detail: String,
        category: IntegrationCategory,
        isPopular: Bool = false,
        search: String,
        aliases: [String],
        symbol: String,
        assetName: String? = nil,
        mode: IntegrationConnectionMode
    ) {
        self.id = id
        self.name = name
        self.detail = detail
        self.category = category
        self.isPopular = isPopular
        self.search = search
        self.aliases = aliases
        self.symbol = symbol
        self.assetName = assetName
        self.mode = mode
    }

    public func matches(_ text: String) -> Bool {
        let normalizedText = " " + Self.normalized(text) + " "
        if normalizedText.contains(" " + Self.normalized(name) + " ") { return true }
        if normalizedText.contains(" " + Self.normalized(id) + " ") { return true }
        return aliases.contains { normalizedText.contains(" " + Self.normalized($0) + " ") }
    }

    private static func normalized(_ text: String) -> String {
        String(text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " }.split(separator: " ").joined(separator: " "))
    }
}

public enum IntegrationCatalog {
    public static func matching(_ text: String) -> IntegrationProviderSpec? {
        all.first { $0.matches(text) }
    }

    public static func byServerID(_ serverID: String) -> IntegrationProviderSpec? {
        if let exact = all.first(where: { $0.id == serverID || "builtin:\($0.id)" == serverID || "apple:\($0.id)" == serverID }) {
            return exact
        }
        return matching(serverID)
    }

    public static let all: [IntegrationProviderSpec] = [
        // MARK: - Apple & iPhone (8)
        .init(id: "apple_calendar", name: "Apple Calendar", detail: "Read, search and schedule events in your iPhone Calendar", category: .apple, isPopular: true, search: "apple calendar", aliases: ["apple calendar", "ical", "ios calendar"], symbol: "calendar", mode: .appleNative(appleKey: "calendar")),
        .init(id: "apple_reminders", name: "Apple Reminders", detail: "Read lists, add reminders and mark items complete on this iPhone", category: .apple, isPopular: true, search: "apple reminders", aliases: ["apple reminders", "ios reminders", "reminders"], symbol: "checklist", mode: .appleNative(appleKey: "reminders")),
        .init(id: "apple_contacts", name: "Apple Contacts", detail: "Search names, emails and phone numbers from your iPhone Contacts", category: .apple, search: "apple contacts", aliases: ["apple contacts", "ios contacts", "address book"], symbol: "person.crop.circle.fill", mode: .appleNative(appleKey: "contacts")),
        .init(id: "icloud_drive", name: "iCloud Drive", detail: "List, read and save files in MAIPA-G's iCloud Drive / Documents folder", category: .apple, search: "icloud drive", aliases: ["icloud drive", "icloud", "files app"], symbol: "icloud.fill", mode: .appleNative(appleKey: "icloud_drive")),
        .init(id: "apple_mail", name: "Apple Mail", detail: "Draft and open pre-filled emails in Apple Mail on your iPhone", category: .apple, search: "apple mail", aliases: ["apple mail", "ios mail"], symbol: "envelope.fill", mode: .appleNative(appleKey: "mail", platformNote: "iOS privacy rules prevent apps from silently reading your Apple Mail inbox; MAIPA-G drafts and opens emails directly in Mail for you to review and send.")),
        .init(id: "imessage", name: "iMessage", detail: "Draft and open pre-filled texts in Apple Messages for you to send", category: .apple, search: "imessage", aliases: ["imessage", "apple messages", "sms"], symbol: "message.fill", mode: .appleNative(appleKey: "imessage", platformNote: "Apple's iOS sandbox blocks third-party apps from reading iMessage history or sending texts silently; MAIPA-G opens your drafted message in Messages ready to send.")),
        .init(id: "apple_notes", name: "Apple Notes", detail: "Prepare formatted notes and send them straight to Apple Notes / Share Sheet", category: .apple, search: "apple notes", aliases: ["apple notes", "ios notes"], symbol: "note.text", mode: .appleNative(appleKey: "notes", platformNote: "iOS does not offer a background API to read existing Apple Notes; MAIPA-G saves and opens drafted notes via iOS Share / Notes.")),
        .init(id: "apple_music", name: "Apple Music", detail: "Search songs, albums, artists and open tracks in Apple Music", category: .apple, search: "apple music", aliases: ["apple music", "itunes"], symbol: "music.note", mode: .publicZeroKey(providerKey: "apple_music")),

        // MARK: - Developer & Cloud (18)
        .init(id: "github", name: "GitHub", detail: "Search repositories, manage issues, pull requests and actions", category: .devCloud, isPopular: true, search: "github", aliases: ["github", "github copilot mcp"], symbol: "chevron.left.forwardslash.chevron.right", assetName: "IntegrationGitHub", mode: .remoteMCP(url: "https://api.githubcopilot.com/mcp/", supportsToken: true, setupHint: "Tap 'Use connected GitHub token' or sign in / paste a GitHub Personal Access Token.")),
        .init(id: "gitlab", name: "GitLab", detail: "Search projects, merge requests, issues and CI pipelines", category: .devCloud, search: "gitlab", aliases: ["gitlab"], symbol: "chevron.left.forwardslash.chevron.right", mode: .apiKeyREST(providerKey: "gitlab", baseURL: "https://gitlab.com/api/v4", authStyle: .header, authName: "PRIVATE-TOKEN", secretLabel: "GitLab Personal Access Token", setupHint: "Paste a GitLab Personal Access Token (`glpat-...`) stored only in Keychain.")),
        .init(id: "bitbucket", name: "Bitbucket", detail: "Browse workspaces, repositories, branches and pull requests", category: .devCloud, search: "bitbucket", aliases: ["bitbucket"], symbol: "chevron.left.forwardslash.chevron.right", assetName: "IntegrationAtlassian", mode: .apiKeyREST(providerKey: "bitbucket", baseURL: "https://api.bitbucket.org/2.0", authStyle: .bearer, secretLabel: "Bitbucket Access Token", setupHint: "Paste a Bitbucket Repository/Workspace Access Token (or connect Atlassian MCP).")),
        .init(id: "linear", name: "Linear", detail: "Search and manage Linear issues, cycles, teams and projects", category: .devCloud, isPopular: true, search: "linear", aliases: ["linear"], symbol: "circle.lefthalf.filled", assetName: "IntegrationLinear", mode: .remoteMCP(url: "https://mcp.linear.app/mcp", supportsToken: true, setupHint: "Sign in with Linear OAuth or paste a Linear API key.")),
        .init(id: "jira", name: "Jira", detail: "Search, create and update Jira issues, sprints and boards", category: .devCloud, isPopular: true, search: "jira", aliases: ["jira", "atlassian"], symbol: "triangle.fill", assetName: "IntegrationAtlassian", mode: .remoteMCP(url: "https://mcp.atlassian.com/v1/mcp", supportsToken: true, setupHint: "Sign in with your Atlassian account via OAuth.")),
        .init(id: "vercel", name: "Vercel", detail: "Inspect deployments, logs, domains and Vercel projects", category: .devCloud, isPopular: true, search: "vercel", aliases: ["vercel"], symbol: "triangle.fill", mode: .remoteMCP(url: "https://mcp.vercel.com", supportsToken: true, setupHint: "Sign in with Vercel OAuth or paste a Vercel Access Token.")),
        .init(id: "cloudflare", name: "Cloudflare", detail: "Manage Workers, KV, D1, R2, DNS and Cloudflare analytics", category: .devCloud, isPopular: true, search: "cloudflare", aliases: ["cloudflare"], symbol: "cloud.fill", mode: .remoteMCP(url: "https://mcp.cloudflare.com/mcp", supportsToken: true, setupHint: "Sign in with Cloudflare OAuth or paste a Cloudflare API Token.")),
        .init(id: "supabase", name: "Supabase", detail: "Inspect tables, SQL migrations, Edge Functions and projects", category: .devCloud, isPopular: true, search: "supabase", aliases: ["supabase"], symbol: "bolt.fill", mode: .remoteMCP(url: "https://mcp.supabase.com/mcp", supportsToken: true, setupHint: "Sign in with Supabase OAuth or paste a Supabase Personal Access Token (`sbp_...`).")),
        .init(id: "firebase", name: "Firebase", detail: "Manage Firebase projects, Firestore, Auth and Hosting via MCP", category: .devCloud, search: "firebase", aliases: ["firebase"], symbol: "flame.fill", mode: .stdioPackage(packageName: "firebase-tools", registryType: "npm", secretEnvNames: ["GOOGLE_APPLICATION_CREDENTIALS_JSON"], plainEnvNames: ["FIREBASE_PROJECT_ID"], setupHint: "Runs via Firebase's MCP package on your connected Linux computer (`mcp-maipa-g`).")),
        .init(id: "aws", name: "AWS", detail: "Query AWS resources, CloudWatch, Lambda and IAM via AWS MCP", category: .devCloud, search: "aws", aliases: ["aws", "amazon web services"], symbol: "server.rack", mode: .stdioPackage(packageName: "@awslabs/core-mcp-server", registryType: "npm", secretEnvNames: ["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"], plainEnvNames: ["AWS_REGION"], setupHint: "Runs on your connected Linux computer (`mcp-maipa-g`) with Keychain AWS credentials.")),
        .init(id: "netlify", name: "Netlify", detail: "List sites, inspect deploy builds and manage Netlify projects", category: .devCloud, search: "netlify", aliases: ["netlify"], symbol: "globe", mode: .apiKeyREST(providerKey: "netlify", baseURL: "https://api.netlify.com/api/v1", authStyle: .bearer, secretLabel: "Netlify Personal Access Token", setupHint: "Paste your Netlify Personal Access Token from User Settings → Applications.")),
        .init(id: "render", name: "Render", detail: "List web services, deploys, logs and databases on Render", category: .devCloud, search: "render", aliases: ["render"], symbol: "cube.fill", mode: .apiKeyREST(providerKey: "render", baseURL: "https://api.render.com/v1", authStyle: .bearer, secretLabel: "Render API Key", setupHint: "Paste your Render API Key (`rnd_...`) from Account Settings → API Keys.")),
        .init(id: "sentry", name: "Sentry", detail: "Investigate stack traces, crashes, issues and releases in Sentry", category: .devCloud, isPopular: true, search: "sentry", aliases: ["sentry"], symbol: "ladybug.fill", mode: .remoteMCP(url: "https://mcp.sentry.dev/mcp", supportsToken: true, setupHint: "Sign in with Sentry OAuth or paste a Sentry Auth Token.")),
        .init(id: "datadog", name: "Datadog", detail: "Search monitors, logs, metrics and incidents in Datadog", category: .devCloud, search: "datadog", aliases: ["datadog"], symbol: "waveform.path.ecg", mode: .apiKeyREST(providerKey: "datadog", baseURL: "https://api.datadoghq.com/api/v1", authStyle: .header, authName: "DD-API-KEY", secretLabel: "Datadog API Key", extraFieldKey: "DD-APPLICATION-KEY", extraFieldLabel: "Datadog Application Key", setupHint: "Enter your Datadog API Key and Application Key.")),
        .init(id: "pagerduty", name: "PagerDuty", detail: "Inspect on-call schedules, alerts and active incidents", category: .devCloud, search: "pagerduty", aliases: ["pagerduty"], symbol: "bell.badge.fill", mode: .apiKeyREST(providerKey: "pagerduty", baseURL: "https://api.pagerduty.com", authStyle: .header, authName: "Authorization", secretLabel: "Token token=YOUR_KEY", setupHint: "Enter `Token token=YOUR_PAGERDUTY_API_KEY`.")),
        .init(id: "sprites", name: "Sprites", detail: "Run Linux commands, code builds and background servers on Fly.io Sprites", category: .devCloud, isPopular: true, search: "sprites", aliases: ["sprites", "sprites.dev", "fly sprites"], symbol: "terminal.fill", mode: .remoteMCP(url: "https://sprites.dev/mcp", supportsToken: true, setupHint: "Sign in with Sprites OAuth or paste a Sprites token.")),
        .init(id: "puppeteer", name: "Puppeteer", detail: "Automate headless Chromium pages and screenshots on your Linux computer", category: .devCloud, search: "puppeteer", aliases: ["puppeteer"], symbol: "safari.fill", mode: .stdioPackage(packageName: "@modelcontextprotocol/server-puppeteer", registryType: "npm", setupHint: "Runs headless browser automation on your connected `mcp-maipa-g` Linux computer.")),
        .init(id: "playwright", name: "Playwright", detail: "Navigate pages, click elements and run browser tests via Microsoft Playwright MCP", category: .devCloud, search: "playwright", aliases: ["playwright"], symbol: "macwindow", mode: .stdioPackage(packageName: "@playwright/mcp", registryType: "npm", setupHint: "Runs Microsoft's official `@playwright/mcp` browser tools on your connected `mcp-maipa-g` computer.")),

        // MARK: - Databases & Storage (10)
        .init(id: "postgresql", name: "PostgreSQL", detail: "Inspect schemas and run SQL queries against PostgreSQL databases", category: .dataStorage, search: "postgres", aliases: ["postgresql", "postgres"], symbol: "cylinder.split.1x2.fill", mode: .stdioPackage(packageName: "@modelcontextprotocol/server-postgres", registryType: "npm", secretEnvNames: ["POSTGRES_URL"], setupHint: "Enter your `postgresql://...` connection string (stored in Keychain) to query via `mcp-maipa-g`.")),
        .init(id: "mongodb", name: "MongoDB", detail: "Explore collections, indexes and documents in MongoDB / Atlas", category: .dataStorage, search: "mongodb", aliases: ["mongodb", "mongo"], symbol: "leaf.fill", mode: .stdioPackage(packageName: "mongodb-mcp-server", registryType: "npm", secretEnvNames: ["MDB_MCP_CONNECTION_STRING"], setupHint: "Enter your `mongodb+srv://...` connection URI (stored in Keychain) to run MongoDB's official MCP server.")),
        .init(id: "redis", name: "Redis", detail: "Inspect keys, hashes, streams and cache entries in Redis / Upstash", category: .dataStorage, search: "redis", aliases: ["redis", "upstash"], symbol: "memorychip.fill", mode: .stdioPackage(packageName: "@modelcontextprotocol/server-redis", registryType: "npm", secretEnvNames: ["REDIS_URL"], setupHint: "Enter your `redis://` or `rediss://` URL (stored in Keychain).")),
        .init(id: "airtable", name: "Airtable", detail: "List bases, search records and update rows in Airtable", category: .dataStorage, search: "airtable", aliases: ["airtable"], symbol: "tablecells.fill", mode: .apiKeyREST(providerKey: "airtable", baseURL: "https://api.airtable.com/v0", authStyle: .bearer, secretLabel: "Airtable Personal Access Token", setupHint: "Paste an Airtable Personal Access Token (`pat...`) from airtable.com/create/tokens.")),
        .init(id: "snowflake", name: "Snowflake", detail: "Query Snowflake warehouses, schemas and tables via Snowflake SQL/MCP", category: .dataStorage, search: "snowflake", aliases: ["snowflake"], symbol: "snowflake", mode: .stdioPackage(packageName: "snowflake-labs-mcp", registryType: "pypi", secretEnvNames: ["SNOWFLAKE_PASSWORD"], plainEnvNames: ["SNOWFLAKE_ACCOUNT", "SNOWFLAKE_USER", "SNOWFLAKE_WAREHOUSE", "SNOWFLAKE_DATABASE"], setupHint: "Runs Snowflake Labs MCP on your connected `mcp-maipa-g` Linux computer.")),
        .init(id: "dropbox", name: "Dropbox", detail: "Search, read and manage cloud folders and files in Dropbox", category: .dataStorage, isPopular: true, search: "dropbox", aliases: ["dropbox"], symbol: "shippingbox.fill", assetName: "IntegrationDropbox", mode: .apiKeyREST(providerKey: "dropbox", baseURL: "https://api.dropboxapi.com/2", authStyle: .bearer, secretLabel: "Dropbox Access Token", setupHint: "Paste a Dropbox OAuth Access Token from the Dropbox App Console.")),
        .init(id: "box", name: "Box", detail: "Search and work with company folders and documents in Box", category: .dataStorage, search: "box", aliases: ["box", "box mcp"], symbol: "archivebox.fill", assetName: "IntegrationBox", mode: .remoteMCP(url: "https://mcp.box.com", supportsToken: true, setupHint: "Sign in with Box OAuth or paste a Box Developer Token.")),
        .init(id: "mega", name: "Mega", detail: "Access encrypted MEGA cloud storage via MEGAcmd / MCP on your Linux computer", category: .dataStorage, search: "mega", aliases: ["mega", "mega.nz"], symbol: "externaldrive.badge.icloud", mode: .stdioPackage(packageName: "mega-mcp", registryType: "npm", secretEnvNames: ["MEGA_PASSWORD"], plainEnvNames: ["MEGA_EMAIL"], setupHint: "Runs MEGA tools on your connected `mcp-maipa-g` Linux computer.")),
        .init(id: "amazon_s3", name: "Amazon S3", detail: "List buckets, inspect objects and read files from Amazon S3 / R2", category: .dataStorage, search: "s3", aliases: ["amazon s3", "aws s3", "s3"], symbol: "externaldrive.fill", mode: .stdioPackage(packageName: "aws-s3-mcp", registryType: "npm", secretEnvNames: ["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"], plainEnvNames: ["AWS_REGION"], setupHint: "Runs S3 MCP on your connected `mcp-maipa-g` Linux computer with Keychain credentials.")),
        .init(id: "google_drive", name: "Google Drive", detail: "Search, read and organize files in Google Drive", category: .dataStorage, isPopular: true, search: "google drive", aliases: ["google drive", "gdrive"], symbol: "externaldrive.fill", assetName: "IntegrationGoogleDrive", mode: .apiKeyREST(providerKey: "google_drive", baseURL: "https://www.googleapis.com/drive/v3", authStyle: .bearer, secretLabel: "Google OAuth Access Token", setupHint: "Paste a Google OAuth token with Drive scope (or connect a Google Workspace MCP server).")),

        // MARK: - Google Workspace & Microsoft 365 (15)
        .init(id: "gmail", name: "Gmail", detail: "Search threads, read messages and create drafts in Gmail", category: .workDocs, isPopular: true, search: "gmail", aliases: ["gmail", "google mail"], symbol: "envelope.fill", assetName: "IntegrationGmail", mode: .apiKeyREST(providerKey: "gmail", baseURL: "https://gmail.googleapis.com/gmail/v1", authStyle: .bearer, secretLabel: "Google OAuth Access Token", setupHint: "Paste a Google OAuth token with `gmail.readonly` / `gmail.compose` scope.")),
        .init(id: "google_calendar", name: "Google Calendar", detail: "List upcoming events, check availability and create Google Calendar events", category: .workDocs, isPopular: true, search: "google calendar", aliases: ["google calendar", "gcalendar"], symbol: "calendar", assetName: "IntegrationGoogleCalendar", mode: .apiKeyREST(providerKey: "google_calendar", baseURL: "https://www.googleapis.com/calendar/v3", authStyle: .bearer, secretLabel: "Google OAuth Access Token", setupHint: "Paste a Google OAuth token with Calendar scope.")),
        .init(id: "google_docs", name: "Google Docs", detail: "Read, create and update documents in Google Docs", category: .workDocs, isPopular: true, search: "google docs", aliases: ["google docs", "gdocs"], symbol: "doc.text.fill", assetName: "IntegrationGoogleDocs", mode: .apiKeyREST(providerKey: "google_docs", baseURL: "https://docs.googleapis.com/v1", authStyle: .bearer, secretLabel: "Google OAuth Access Token", setupHint: "Paste a Google OAuth token with `documents` scope.")),
        .init(id: "google_sheets", name: "Google Sheets", detail: "Read ranges, analyze rows and update cells in Google Sheets", category: .workDocs, isPopular: true, search: "google sheets", aliases: ["google sheets", "gsheets"], symbol: "tablecells.fill", assetName: "IntegrationGoogleSheets", mode: .apiKeyREST(providerKey: "google_sheets", baseURL: "https://sheets.googleapis.com/v4", authStyle: .bearer, secretLabel: "Google OAuth Access Token", setupHint: "Paste a Google OAuth token with `spreadsheets` scope.")),
        .init(id: "google_slides", name: "Google Slides", detail: "Read slide decks and build presentations in Google Slides", category: .workDocs, search: "google slides", aliases: ["google slides", "gslides"], symbol: "rectangle.on.rectangle.angled", assetName: "IntegrationGoogleSlides", mode: .apiKeyREST(providerKey: "google_slides", baseURL: "https://slides.googleapis.com/v1", authStyle: .bearer, secretLabel: "Google OAuth Access Token", setupHint: "Paste a Google OAuth token with `presentations` scope.")),
        .init(id: "google_tasks", name: "Google Tasks", detail: "List task lists, add tasks and complete to-dos in Google Tasks", category: .workDocs, search: "google tasks", aliases: ["google tasks", "gtasks"], symbol: "checkmark.circle.fill", mode: .apiKeyREST(providerKey: "google_tasks", baseURL: "https://tasks.googleapis.com/tasks/v1", authStyle: .bearer, secretLabel: "Google OAuth Access Token", setupHint: "Paste a Google OAuth token with `tasks` scope.")),
        .init(id: "google_contacts", name: "Google Contacts", detail: "Search and look up people in Google Contacts (People API)", category: .workDocs, search: "google contacts", aliases: ["google contacts", "google people"], symbol: "person.2.fill", mode: .apiKeyREST(providerKey: "google_contacts", baseURL: "https://people.googleapis.com/v1", authStyle: .bearer, secretLabel: "Google OAuth Access Token", setupHint: "Paste a Google OAuth token with `contacts.readonly` scope.")),
        .init(id: "google_meet", name: "Google Meet", detail: "Create meeting spaces and inspect Google Meet conference records", category: .chatMeetings, search: "google meet", aliases: ["google meet", "gmeet"], symbol: "video.fill", mode: .apiKeyREST(providerKey: "google_meet", baseURL: "https://meet.googleapis.com/v2", authStyle: .bearer, secretLabel: "Google OAuth Access Token", setupHint: "Paste a Google OAuth token with Google Meet REST API scope.")),
        .init(id: "microsoft_365", name: "Microsoft 365", detail: "Work across Outlook, OneDrive, Teams, SharePoint and Office via Microsoft Graph", category: .workDocs, isPopular: true, search: "microsoft 365", aliases: ["microsoft 365", "office 365", "m365"], symbol: "square.grid.2x2.fill", assetName: "IntegrationMicrosoft", mode: .apiKeyREST(providerKey: "microsoft_365", baseURL: "https://graph.microsoft.com/v1.0", authStyle: .bearer, secretLabel: "Microsoft Graph Access Token", setupHint: "Paste a Microsoft Graph OAuth token (from Graph Explorer / Entra App) stored in Keychain.")),
        .init(id: "outlook", name: "Outlook", detail: "Search mail, read calendar events and draft replies in Microsoft Outlook", category: .workDocs, search: "outlook", aliases: ["outlook", "microsoft outlook"], symbol: "envelope.badge.fill", assetName: "IntegrationMicrosoft", mode: .apiKeyREST(providerKey: "outlook", baseURL: "https://graph.microsoft.com/v1.0/me", authStyle: .bearer, secretLabel: "Microsoft Graph Access Token", setupHint: "Paste a Microsoft Graph token with `Mail.Read` / `Calendars.ReadWrite`.")),
        .init(id: "onedrive", name: "OneDrive", detail: "Browse folders, search documents and read files in Microsoft OneDrive", category: .dataStorage, search: "onedrive", aliases: ["onedrive", "microsoft onedrive"], symbol: "cloud.fill", assetName: "IntegrationMicrosoft", mode: .apiKeyREST(providerKey: "onedrive", baseURL: "https://graph.microsoft.com/v1.0/me/drive", authStyle: .bearer, secretLabel: "Microsoft Graph Access Token", setupHint: "Paste a Microsoft Graph token with `Files.ReadWrite`.")),
        .init(id: "sharepoint", name: "SharePoint", detail: "Search SharePoint sites, document libraries and lists", category: .workDocs, search: "sharepoint", aliases: ["sharepoint", "microsoft sharepoint"], symbol: "folder.badge.person.crop", assetName: "IntegrationMicrosoft", mode: .apiKeyREST(providerKey: "sharepoint", baseURL: "https://graph.microsoft.com/v1.0/sites", authStyle: .bearer, secretLabel: "Microsoft Graph Access Token", setupHint: "Paste a Microsoft Graph token with `Sites.Read.All`.")),
        .init(id: "microsoft_word", name: "Microsoft Word", detail: "Locate and inspect Word `.docx` files on OneDrive / SharePoint", category: .workDocs, search: "microsoft word", aliases: ["microsoft word", "ms word"], symbol: "doc.richtext.fill", assetName: "IntegrationMicrosoft", mode: .apiKeyREST(providerKey: "microsoft_word", baseURL: "https://graph.microsoft.com/v1.0/me/drive", authStyle: .bearer, secretLabel: "Microsoft Graph Access Token", setupHint: "Paste a Microsoft Graph token with `Files.ReadWrite` (MAIPA-G can also build `.docx` files directly on your computer).")),
        .init(id: "microsoft_excel", name: "Microsoft Excel", detail: "Read and update Excel workbook tables and ranges via Microsoft Graph", category: .workDocs, search: "microsoft excel", aliases: ["microsoft excel", "ms excel"], symbol: "tablecells.badge.ellipsis", assetName: "IntegrationMicrosoft", mode: .apiKeyREST(providerKey: "microsoft_excel", baseURL: "https://graph.microsoft.com/v1.0/me/drive", authStyle: .bearer, secretLabel: "Microsoft Graph Access Token", setupHint: "Paste a Microsoft Graph token with `Files.ReadWrite`.")),
        .init(id: "microsoft_onenote", name: "Microsoft OneNote", detail: "List notebooks, sections and read/create pages in OneNote", category: .workDocs, search: "onenote", aliases: ["microsoft onenote", "onenote"], symbol: "book.closed.fill", assetName: "IntegrationMicrosoft", mode: .apiKeyREST(providerKey: "microsoft_onenote", baseURL: "https://graph.microsoft.com/v1.0/me/onenote", authStyle: .bearer, secretLabel: "Microsoft Graph Access Token", setupHint: "Paste a Microsoft Graph token with `Notes.ReadWrite`.")),

        // MARK: - Notes, Docs, Design & Tasks (16)
        .init(id: "notion", name: "Notion", detail: "Search pages, query databases and update your Notion workspace", category: .workDocs, isPopular: true, search: "notion", aliases: ["notion"], symbol: "doc.text", assetName: "IntegrationNotion", mode: .remoteMCP(url: "https://mcp.notion.com/mcp", supportsToken: true, setupHint: "Sign in with Notion OAuth or paste a Notion Internal Integration Secret (`ntn_...`).")),
        .init(id: "obsidian", name: "Obsidian", detail: "Create Markdown notes and open them directly in your Obsidian vault on iPhone", category: .workDocs, search: "obsidian", aliases: ["obsidian"], symbol: "sparkles.rectangle.stack.fill", mode: .appleNative(appleKey: "obsidian", platformNote: "Uses Obsidian's `obsidian://new` URL scheme and Markdown files in iCloud/Documents so notes open straight in your vault.")),
        .init(id: "confluence", name: "Confluence", detail: "Search spaces, read wiki pages and update Confluence docs", category: .workDocs, search: "confluence", aliases: ["confluence"], symbol: "book.fill", assetName: "IntegrationAtlassian", mode: .remoteMCP(url: "https://mcp.atlassian.com/v1/mcp", supportsToken: true, setupHint: "Sign in with your Atlassian account via OAuth.")),
        .init(id: "coda", name: "Coda", detail: "List docs, read tables and insert/update rows in Coda", category: .workDocs, search: "coda", aliases: ["coda", "coda.io"], symbol: "doc.append.fill", mode: .apiKeyREST(providerKey: "coda", baseURL: "https://coda.io/apis/v1", authStyle: .bearer, secretLabel: "Coda API Token", setupHint: "Paste your Coda API Token from coda.io/account.")),
        .init(id: "evernote", name: "Evernote", detail: "Prepare rich notes and send them straight to Evernote on iPhone", category: .workDocs, search: "evernote", aliases: ["evernote"], symbol: "note.text.badge.plus", mode: .appleNative(appleKey: "evernote")),
        .init(id: "capacities", name: "Capacities", detail: "Search spaces, read daily notes and save weblinks/notes to Capacities", category: .workDocs, search: "capacities", aliases: ["capacities", "capacities.io"], symbol: "square.stack.3d.up.fill", mode: .apiKeyREST(providerKey: "capacities", baseURL: "https://api.capacities.io", authStyle: .bearer, secretLabel: "Capacities API Token", setupHint: "Paste your Capacities API Token from Capacities Settings → API.")),
        .init(id: "trello", name: "Trello", detail: "Read boards, lists and create/move cards in Trello", category: .workDocs, search: "trello", aliases: ["trello"], symbol: "rectangle.split.3x1.fill", mode: .apiKeyREST(providerKey: "trello", baseURL: "https://api.trello.com/1", authStyle: .queryParam, authName: "token", secretLabel: "Trello Token", extraFieldKey: "key", extraFieldLabel: "Trello API Key", setupHint: "Enter your Trello API Key and Token from trello.com/power-ups/admin.")),
        .init(id: "asana", name: "Asana", detail: "Search tasks, manage projects and update status in Asana", category: .workDocs, isPopular: true, search: "asana", aliases: ["asana"], symbol: "circle.grid.3x3.fill", assetName: "IntegrationAsana", mode: .apiKeyREST(providerKey: "asana", baseURL: "https://app.asana.com/api/1.0", authStyle: .bearer, secretLabel: "Asana Personal Access Token", setupHint: "Paste an Asana Personal Access Token from Asana Developer Console.")),
        .init(id: "monday", name: "Monday.com", detail: "Inspect boards, items, columns and updates in Monday.com", category: .workDocs, search: "monday", aliases: ["monday.com", "monday"], symbol: "calendar.day.timeline.left", mode: .remoteMCP(url: "https://mcp.monday.com/mcp", supportsToken: true, setupHint: "Sign in with Monday.com OAuth or paste your Monday API v2 Token.")),
        .init(id: "clickup", name: "ClickUp", detail: "Search spaces, lists, tasks and comments in ClickUp", category: .workDocs, search: "clickup", aliases: ["clickup"], symbol: "checkmark.diamond.fill", mode: .apiKeyREST(providerKey: "clickup", baseURL: "https://api.clickup.com/api/v2", authStyle: .header, authName: "Authorization", secretLabel: "ClickUp Personal API Token (`pk_...`)", setupHint: "Paste your ClickUp Personal Token (`pk_...`) from ClickUp Settings → Apps.")),
        .init(id: "todoist", name: "Todoist", detail: "List active tasks, projects and add/complete tasks in Todoist", category: .workDocs, search: "todoist", aliases: ["todoist"], symbol: "checkmark.circle", mode: .apiKeyREST(providerKey: "todoist", baseURL: "https://api.todoist.com/rest/v2", authStyle: .bearer, secretLabel: "Todoist API Token", setupHint: "Paste your Todoist API Token from Settings → Integrations → Developer.")),
        .init(id: "basecamp", name: "Basecamp", detail: "Browse Basecamp projects, message boards, to-do lists and campfires", category: .workDocs, search: "basecamp", aliases: ["basecamp"], symbol: "tent.fill", mode: .apiKeyREST(providerKey: "basecamp", baseURL: "https://3.basecampapi.com", authStyle: .bearer, secretLabel: "Basecamp OAuth Access Token", extraFieldKey: "account_id", extraFieldLabel: "Basecamp Account ID", setupHint: "Enter your Basecamp Account ID and OAuth Access Token.")),
        .init(id: "smartsheet", name: "Smartsheet", detail: "List sheets, inspect rows and update cells in Smartsheet", category: .workDocs, search: "smartsheet", aliases: ["smartsheet"], symbol: "tablecells", mode: .apiKeyREST(providerKey: "smartsheet", baseURL: "https://api.smartsheet.com/2.0", authStyle: .bearer, secretLabel: "Smartsheet Access Token", setupHint: "Paste a Smartsheet API Access Token from Personal Settings → API Access.")),
        .init(id: "figma", name: "Figma", detail: "Inspect Figma files, frames, design tokens and comments", category: .workDocs, isPopular: true, search: "figma", aliases: ["figma"], symbol: "paintbrush.pointed.fill", assetName: "IntegrationFigma", mode: .remoteMCP(url: "https://mcp.figma.com/mcp", supportsToken: true, setupHint: "Sign in with Figma OAuth or paste a Figma Personal Access Token (`figd_...`).")),
        .init(id: "canva", name: "Canva", detail: "Search, inspect and generate designs in Canva", category: .workDocs, isPopular: true, search: "canva", aliases: ["canva"], symbol: "wand.and.stars", assetName: "IntegrationCanva", mode: .remoteMCP(url: "https://mcp.canva.com/mcp", supportsToken: true, setupHint: "Sign in with your Canva account via OAuth.")),
        .init(id: "miro", name: "Miro", detail: "List boards, read sticky notes, cards and frames in Miro", category: .workDocs, search: "miro", aliases: ["miro"], symbol: "rectangle.3.group.fill", mode: .apiKeyREST(providerKey: "miro", baseURL: "https://api.miro.com/v2", authStyle: .bearer, secretLabel: "Miro Access Token", setupHint: "Paste a Miro OAuth Access Token from Miro Developer Settings.")),

        // MARK: - Messaging & Meetings (9)
        .init(id: "slack", name: "Slack", detail: "Search channels, read threads and post messages in Slack", category: .chatMeetings, isPopular: true, search: "slack", aliases: ["slack"], symbol: "number", assetName: "IntegrationSlack", mode: .remoteMCP(url: "https://mcp.slack.com/mcp", supportsToken: true, setupHint: "Sign in with Slack OAuth or paste a Slack User/Bot Token (`xoxp-...` / `xoxb-...`).")),
        .init(id: "microsoft_teams", name: "Microsoft Teams", detail: "List joined Teams, channels and read/send channel messages", category: .chatMeetings, search: "microsoft teams", aliases: ["microsoft teams", "ms teams", "teams"], symbol: "person.3.fill", assetName: "IntegrationMicrosoft", mode: .apiKeyREST(providerKey: "microsoft_teams", baseURL: "https://graph.microsoft.com/v1.0", authStyle: .bearer, secretLabel: "Microsoft Graph Access Token", setupHint: "Paste a Microsoft Graph token with `Team.ReadBasic.All` / `ChannelMessage.Read.All`.")),
        .init(id: "discord", name: "Discord", detail: "Read channel messages, list guild channels and post via Discord Bot API", category: .chatMeetings, search: "discord", aliases: ["discord"], symbol: "bubble.left.and.bubble.right.fill", mode: .apiKeyREST(providerKey: "discord", baseURL: "https://discord.com/api/v10", authStyle: .header, authName: "Authorization", secretLabel: "Bot YOUR_DISCORD_BOT_TOKEN", setupHint: "Enter `Bot YOUR_TOKEN` from Discord Developer Portal.")),
        .init(id: "telegram", name: "Telegram", detail: "Receive bot updates and send messages or documents via Telegram Bot API", category: .chatMeetings, search: "telegram", aliases: ["telegram"], symbol: "paperplane.fill", mode: .apiKeyREST(providerKey: "telegram", baseURL: "https://api.telegram.org", authStyle: .telegramBotPath, secretLabel: "Telegram Bot Token (`123456:ABC...`)", setupHint: "Paste your BotFather token (`123456:ABC-DEF...`) stored in Keychain.")),
        .init(id: "whatsapp", name: "WhatsApp", detail: "Send messages via Meta WhatsApp Cloud API or open pre-filled WhatsApp chats", category: .chatMeetings, search: "whatsapp", aliases: ["whatsapp"], symbol: "phone.bubble.fill", mode: .apiKeyREST(providerKey: "whatsapp", baseURL: "https://graph.facebook.com/v20.0", authStyle: .bearer, secretLabel: "WhatsApp Cloud API Token (optional for wa.me compose)", extraFieldKey: "phone_number_id", extraFieldLabel: "WhatsApp Phone Number ID", setupHint: "Enter Meta WhatsApp Cloud API credentials for automated messaging (personal WhatsApp chats do not offer a background read API on iOS).")),
        .init(id: "zoom", name: "Zoom", detail: "List upcoming Zoom meetings, recordings and create meeting links", category: .chatMeetings, search: "zoom", aliases: ["zoom"], symbol: "video.circle.fill", mode: .apiKeyREST(providerKey: "zoom", baseURL: "https://api.zoom.us/v2", authStyle: .bearer, secretLabel: "Zoom OAuth Access Token", setupHint: "Paste a Zoom Server-to-Server OAuth or User OAuth token.")),
        .init(id: "loom", name: "Loom", detail: "Fetch Loom video metadata, oEmbed details and transcripts", category: .chatMeetings, search: "loom", aliases: ["loom"], symbol: "record.circle.fill", mode: .apiKeyREST(providerKey: "loom", baseURL: "https://www.loom.com/v1", authStyle: .bearer, secretLabel: "Loom Developer Token (or public oEmbed)", setupHint: "Paste a Loom API token (or leave blank to inspect public Loom share links via oEmbed).")),
        .init(id: "fireflies", name: "Fireflies.ai", detail: "Search meeting transcripts, action items and summaries in Fireflies.ai", category: .chatMeetings, search: "fireflies", aliases: ["fireflies.ai", "fireflies"], symbol: "waveform.and.mic", mode: .apiKeyREST(providerKey: "fireflies", baseURL: "https://api.fireflies.ai/graphql", authStyle: .bearer, secretLabel: "Fireflies.ai API Key", setupHint: "Paste your Fireflies API key from Fireflies Integrations → Fireflies API.")),
        .init(id: "otter", name: "Otter.ai", detail: "Access synced Otter.ai meeting summaries and push transcripts via webhook/API", category: .chatMeetings, search: "otter", aliases: ["otter.ai", "otter"], symbol: "mic.fill", mode: .apiKeyREST(providerKey: "otter", baseURL: "https://otter.ai/forward/api/v1", authStyle: .bearer, secretLabel: "Otter API / Session Token", setupHint: "Paste your Otter API token (or export transcripts via Zapier/Webhook into MAIPA-G).")),

        // MARK: - Search, Web, AI & Media (17)
        .init(id: "wikipedia", name: "Wikipedia", detail: "Search Wikipedia articles and read verified encyclopedic summaries — no key needed", category: .searchMedia, isPopular: true, search: "wikipedia", aliases: ["wikipedia", "wiki"], symbol: "book.pages.fill", mode: .publicZeroKey(providerKey: "wikipedia")),
        .init(id: "arxiv", name: "ArXiv", detail: "Search scientific papers, abstracts and PDF links on arXiv.org — no key needed", category: .searchMedia, isPopular: true, search: "arxiv", aliases: ["arxiv"], symbol: "graduationcap.fill", mode: .publicZeroKey(providerKey: "arxiv")),
        .init(id: "hacker_news", name: "Hacker News", detail: "Read front-page stories, search Algolia HN archives and inspect comments — no key needed", category: .searchMedia, isPopular: true, search: "hacker news", aliases: ["hacker news", "hn", "ycombinator"], symbol: "newspaper.fill", mode: .publicZeroKey(providerKey: "hackernews")),
        .init(id: "reddit", name: "Reddit", detail: "Search subreddits, hot threads and public comment discussions — no key needed", category: .searchMedia, search: "reddit", aliases: ["reddit"], symbol: "text.bubble.fill", mode: .publicZeroKey(providerKey: "reddit")),
        .init(id: "jina_reader", name: "Jina Reader", detail: "Convert any web page or PDF URL into clean LLM-ready Markdown — works immediately", category: .searchMedia, isPopular: true, search: "jina", aliases: ["jina reader", "jina", "r.jina.ai"], symbol: "doc.plaintext.fill", mode: .publicZeroKey(providerKey: "jina")),
        .init(id: "brave_search", name: "Brave Search", detail: "Fast independent web & news search via the Brave Search API", category: .searchMedia, isPopular: true, search: "brave search", aliases: ["brave search", "brave"], symbol: "magnifyingglass.circle.fill", mode: .apiKeyREST(providerKey: "brave", baseURL: "https://api.search.brave.com/res/v1", authStyle: .header, authName: "X-Subscription-Token", secretLabel: "Brave Search API Key", setupHint: "Paste your `BSA...` key from brave.com/search/api.")),
        .init(id: "google_search", name: "Google Search", detail: "Run Programmable Google Web Search queries via Google Custom Search JSON API", category: .searchMedia, search: "google search", aliases: ["google search", "google custom search"], symbol: "magnifyingglass", mode: .apiKeyREST(providerKey: "google_search", baseURL: "https://customsearch.googleapis.com/customsearch/v1", authStyle: .queryParam, authName: "key", secretLabel: "Google API Key", extraFieldKey: "cx", extraFieldLabel: "Search Engine ID (cx)", setupHint: "Enter your Google Cloud API Key and Programmable Search Engine ID (`cx`).")),
        .init(id: "perplexity", name: "Perplexity", detail: "Deep web-grounded research with citations using Perplexity Sonar API", category: .searchMedia, isPopular: true, search: "perplexity", aliases: ["perplexity", "sonar"], symbol: "sparkle.magnifyingglass", mode: .apiKeyREST(providerKey: "perplexity", baseURL: "https://api.perplexity.ai", authStyle: .bearer, secretLabel: "Perplexity API Key (`pplx-...`)", setupHint: "Paste your `pplx-...` API key from perplexity.ai/settings/api.")),
        .init(id: "tavily", name: "Tavily", detail: "AI-optimized web search and page extraction via Tavily Remote MCP or API", category: .searchMedia, search: "tavily", aliases: ["tavily"], symbol: "globe.americas.fill", mode: .apiKeyREST(providerKey: "tavily", baseURL: "https://api.tavily.com", authStyle: .bearer, secretLabel: "Tavily API Key (`tvly-...`)", setupHint: "Paste your `tvly-...` key from app.tavily.com.")),
        .init(id: "exa", name: "Exa", detail: "Neural semantic search across papers, code, companies and the web", category: .searchMedia, search: "exa", aliases: ["exa", "exa.ai", "metaphor"], symbol: "network", mode: .apiKeyREST(providerKey: "exa", baseURL: "https://api.exa.ai", authStyle: .header, authName: "x-api-key", secretLabel: "Exa API Key", setupHint: "Paste your Exa API Key from dashboard.exa.ai.")),
        .init(id: "newsapi", name: "NewsAPI", detail: "Search breaking headlines and global news articles via NewsAPI.org", category: .searchMedia, search: "newsapi", aliases: ["newsapi", "news api"], symbol: "newspaper", mode: .apiKeyREST(providerKey: "newsapi", baseURL: "https://newsapi.org/v2", authStyle: .header, authName: "X-Api-Key", secretLabel: "NewsAPI Key", setupHint: "Paste your API key from newsapi.org.")),
        .init(id: "firecrawl", name: "Firecrawl", detail: "Scrape, crawl and extract structured Markdown from JS-heavy websites", category: .searchMedia, search: "firecrawl", aliases: ["firecrawl"], symbol: "flame.circle.fill", mode: .apiKeyREST(providerKey: "firecrawl", baseURL: "https://api.firecrawl.dev/v1", authStyle: .bearer, secretLabel: "Firecrawl API Key (`fc-...`)", setupHint: "Paste your `fc-...` key from firecrawl.dev.")),
        .init(id: "twitter", name: "X (Twitter)", detail: "Search recent posts, look up profiles and post updates via X API v2", category: .searchMedia, search: "twitter", aliases: ["x", "twitter", "x twitter"], symbol: "at", mode: .apiKeyREST(providerKey: "twitter", baseURL: "https://api.x.com/2", authStyle: .bearer, secretLabel: "X API v2 Bearer Token", setupHint: "Paste your X Developer Portal Bearer Token.")),
        .init(id: "huggingface", name: "Hugging Face", detail: "Search open-source models, datasets, papers and Spaces", category: .searchMedia, isPopular: true, search: "huggingface", aliases: ["hugging face", "huggingface", "hf mcp server"], symbol: "face.smiling", assetName: "IntegrationHuggingFace", mode: .remoteMCP(url: "https://huggingface.co/mcp", supportsToken: true, setupHint: "Sign in with Hugging Face OAuth or paste an `hf_...` token.")),
        .init(id: "spotify", name: "Spotify", detail: "Search tracks, playlists, artists and inspect playback via Spotify Web API", category: .searchMedia, search: "spotify", aliases: ["spotify"], symbol: "waveform.circle.fill", mode: .apiKeyREST(providerKey: "spotify", baseURL: "https://api.spotify.com/v1", authStyle: .bearer, secretLabel: "Spotify OAuth Access Token", setupHint: "Paste a Spotify Web API Bearer token.")),
        .init(id: "youtube", name: "YouTube", detail: "Search YouTube videos, channels, playlists and captions via YouTube Data API v3", category: .searchMedia, isPopular: true, search: "youtube", aliases: ["youtube"], symbol: "play.rectangle.fill", assetName: "IntegrationYouTube", mode: .apiKeyREST(providerKey: "youtube", baseURL: "https://www.googleapis.com/youtube/v3", authStyle: .queryParam, authName: "key", secretLabel: "YouTube Data API v3 Key", setupHint: "Paste a Google Cloud API Key with YouTube Data API v3 enabled.")),
        .init(id: "elevenlabs", name: "ElevenLabs", detail: "List realistic voices and inspect text-to-speech models via ElevenLabs API", category: .searchMedia, search: "elevenlabs", aliases: ["elevenlabs", "eleven labs"], symbol: "speaker.wave.3.fill", mode: .apiKeyREST(providerKey: "elevenlabs", baseURL: "https://api.elevenlabs.io/v1", authStyle: .header, authName: "xi-api-key", secretLabel: "ElevenLabs API Key (`sk_...`)", setupHint: "Paste your `xi-api-key` from elevenlabs.io.")),

        // MARK: - CRM, Commerce & Automation (14)
        .init(id: "stripe", name: "Stripe", detail: "Inspect customers, subscriptions, invoices and payments via Stripe MCP", category: .businessAuto, isPopular: true, search: "stripe", aliases: ["stripe"], symbol: "creditcard.fill", mode: .remoteMCP(url: "https://mcp.stripe.com", supportsToken: true, setupHint: "Sign in with Stripe OAuth or paste a restricted Stripe key (`rk_...`).")),
        .init(id: "hubspot", name: "HubSpot", detail: "Search CRM contacts, deals, companies and tickets via HubSpot MCP", category: .businessAuto, search: "hubspot", aliases: ["hubspot"], symbol: "person.crop.rectangle.stack.fill", mode: .remoteMCP(url: "https://mcp.hubspot.com", supportsToken: true, setupHint: "Sign in with HubSpot OAuth or paste a HubSpot Private App Token.")),
        .init(id: "intercom", name: "Intercom", detail: "Search customer conversations, contacts and help articles via Intercom MCP", category: .businessAuto, search: "intercom", aliases: ["intercom"], symbol: "bubble.left.and.text.bubble.right.fill", mode: .remoteMCP(url: "https://mcp.intercom.com/mcp", supportsToken: true, setupHint: "Sign in with Intercom OAuth or paste an Intercom Access Token.")),
        .init(id: "paypal", name: "PayPal", detail: "Work with invoices, orders, disputes and transactions via PayPal MCP", category: .businessAuto, search: "paypal", aliases: ["paypal"], symbol: "dollarsign.circle.fill", mode: .remoteMCP(url: "https://mcp.paypal.com/mcp", supportsToken: true, setupHint: "Sign in with PayPal OAuth or paste a PayPal Access Token.")),
        .init(id: "salesforce", name: "Salesforce", detail: "Run SOQL queries and inspect Leads, Accounts and Opportunities", category: .businessAuto, search: "salesforce", aliases: ["salesforce", "sfdc"], symbol: "cloud.sun.fill", mode: .apiKeyREST(providerKey: "salesforce", baseURL: "https://login.salesforce.com", authStyle: .bearer, secretLabel: "Salesforce Access Token", extraFieldKey: "instance_url", extraFieldLabel: "Instance URL (e.g. https://yourorg.my.salesforce.com)", setupHint: "Enter your Salesforce Instance URL and OAuth Access Token.")),
        .init(id: "zendesk", name: "Zendesk", detail: "Search support tickets, users and help-center articles in Zendesk", category: .businessAuto, search: "zendesk", aliases: ["zendesk"], symbol: "headphones", mode: .apiKeyREST(providerKey: "zendesk", baseURL: "https://api.zendesk.com", authStyle: .bearer, secretLabel: "Zendesk OAuth / API Token", extraFieldKey: "subdomain", extraFieldLabel: "Zendesk Subdomain (e.g. acme)", setupHint: "Enter your Zendesk subdomain (`acme` for `acme.zendesk.com`) and OAuth Bearer token.")),
        .init(id: "shopify", name: "Shopify", detail: "Query products, orders, inventory and customers via Shopify Admin API", category: .businessAuto, search: "shopify", aliases: ["shopify"], symbol: "bag.fill", mode: .apiKeyREST(providerKey: "shopify", baseURL: "https://shopify.com", authStyle: .header, authName: "X-Shopify-Access-Token", secretLabel: "Shopify Admin Access Token (`shpat_...`)", extraFieldKey: "shop_domain", extraFieldLabel: "Store Domain (e.g. my-store.myshopify.com)", setupHint: "Enter your `*.myshopify.com` domain and Admin API token (`shpat_...`).")),
        .init(id: "quickbooks", name: "QuickBooks", detail: "Query invoices, customers, bills and P&L reports in QuickBooks Online", category: .businessAuto, search: "quickbooks", aliases: ["quickbooks", "intuit quickbooks"], symbol: "chart.pie.fill", mode: .apiKeyREST(providerKey: "quickbooks", baseURL: "https://quickbooks.api.intuit.com/v3/company", authStyle: .bearer, secretLabel: "QuickBooks OAuth Access Token", extraFieldKey: "realm_id", extraFieldLabel: "Company / Realm ID", setupHint: "Enter your QuickBooks Realm ID and OAuth Bearer token.")),
        .init(id: "zapier", name: "Zapier", detail: "Connect 7,000+ apps through your personal Zapier MCP endpoint", category: .businessAuto, isPopular: true, search: "zapier", aliases: ["zapier"], symbol: "bolt.horizontal.fill", mode: .remoteMCP(url: "https://mcp.zapier.com", supportsToken: true, setupHint: "Sign in with Zapier or paste your Zapier MCP URL/token from mcp.zapier.com.")),
        .init(id: "pipedream", name: "Pipedream", detail: "Run 2,500+ API workflows and managed OAuth actions via Pipedream MCP", category: .businessAuto, search: "pipedream", aliases: ["pipedream"], symbol: "arrow.triangle.branch", mode: .remoteMCP(url: "https://remote.mcp.pipedream.net", supportsToken: true, setupHint: "Sign in with Pipedream or paste a Pipedream token.")),
        .init(id: "make", name: "Make", detail: "List scenarios or trigger Make.com automation webhooks & API v2", category: .businessAuto, search: "make", aliases: ["make", "make.com", "integromat"], symbol: "gearshape.2.fill", mode: .apiKeyREST(providerKey: "make", baseURL: "https://us1.make.com/api/v2", authStyle: .header, authName: "Authorization", secretLabel: "Token YOUR_MAKE_API_TOKEN", extraFieldKey: "zone_url", extraFieldLabel: "Zone Base URL (optional, e.g. https://eu1.make.com/api/v2)", setupHint: "Enter `Token YOUR_API_KEY` (or use Custom Webhooks to trigger a Make webhook directly).")),
        .init(id: "n8n", name: "n8n", detail: "List workflows, inspect executions and trigger self-hosted or cloud n8n", category: .businessAuto, search: "n8n", aliases: ["n8n", "n8n.io"], symbol: "point.3.filled.connected.trianglepath.dotted", mode: .apiKeyREST(providerKey: "n8n", baseURL: "https://app.n8n.cloud/api/v1", authStyle: .header, authName: "X-N8N-API-KEY", secretLabel: "n8n API Key", extraFieldKey: "instance_url", extraFieldLabel: "n8n Base URL (e.g. https://n8n.example.com/api/v1)", setupHint: "Enter your n8n instance URL and `X-N8N-API-KEY` (or connect n8n's MCP endpoint).")),
        .init(id: "custom_webhooks", name: "Custom Webhooks", detail: "Trigger any HTTPS webhook URL (Make, n8n, Discord, Slack, custom backends) with JSON", category: .businessAuto, isPopular: true, search: "webhook", aliases: ["custom webhooks", "webhooks", "webhook"], symbol: "paperplane.circle.fill", mode: .customWebhook),
        .init(id: "custom_mcp", name: "Custom MCP", detail: "Connect any HTTPS Model Context Protocol server with OAuth or a custom API header", category: .devCloud, isPopular: true, search: "custom mcp", aliases: ["custom mcp", "mcp server"], symbol: "puzzlepiece.extension.fill", mode: .customMCP),
    ]
}

// MARK: - Built-in Public, REST, Webhook & Stdio-Computer Tools

public enum BuiltinIntegrationFactory {
    public static func definitions(for configuration: ConnectorConfiguration) -> [ConnectorToolDefinition] {
        switch configuration.kind {
        case .webhook:
            let def = WebhookConnectorTool(configuration: configuration, secretValue: nil, transport: NoopHTTPTransport()).definition
            return [def]
        case .builtin:
            return makeBuiltinTools(configuration: configuration, secret: nil, transport: NoopHTTPTransport())
                .map(\.definition)
        case .stdio:
            let def = ConnectorToolDefinition(
                serverID: configuration.serverID,
                serverName: configuration.displayName,
                originalName: "call",
                title: "Call \(configuration.displayName) MCP",
                description: "List tools (`method: \"tools/list\"`) or call a tool (`method: \"tools/call\"`, `params: {\"name\": \"...\", \"arguments\": {...}}`) on \(configuration.displayName).",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "method": ["type": "string", "description": "Either \"tools/list\" or \"tools/call\"."],
                        "params": ["type": "object", "description": "For tools/call: {\"name\": \"tool_name\", \"arguments\": {...}}."]
                    ],
                    "required": ["method"]
                ]
            )
            return [def]
        case .remote, .apple:
            return []
        }
    }

    public static func tools(
        for configuration: ConnectorConfiguration,
        secret: String?,
        transport: any HTTPTransport,
        computer: ComputerControl?,
        stdioEnvSecrets: [String: String] = [:]
    ) -> [any AgentTool] {
        let disabled = configuration.disabledTools
        switch configuration.kind {
        case .webhook:
            let tool = WebhookConnectorTool(configuration: configuration, secretValue: secret, transport: transport)
            return disabled.contains(tool.definition.originalName) ? [] : [tool]
        case .builtin:
            return makeBuiltinTools(configuration: configuration, secret: secret, transport: transport)
                .filter { !disabled.contains($0.definition.originalName) }
        case .stdio:
            guard let computer, let pkg = configuration.package, !disabled.contains("call") else { return [] }
            return [StdioComputerBridgeTool(configuration: configuration, package: pkg, secrets: stdioEnvSecrets, computer: computer)]
        case .remote, .apple:
            return []
        }
    }

    private static func makeBuiltinTools(
        configuration: ConnectorConfiguration,
        secret: String?,
        transport: any HTTPTransport
    ) -> [any BuiltinDescribedTool] {
        let provider = configuration.launchValues["provider"] ?? configuration.serverID.replacingOccurrences(of: "builtin:", with: "")
        switch provider {
        case "wikipedia":
            return [WikipediaSearchTool(configuration: configuration, transport: transport), WikipediaSummaryTool(configuration: configuration, transport: transport)]
        case "arxiv":
            return [ArXivSearchTool(configuration: configuration, transport: transport)]
        case "hackernews", "hacker_news":
            return [HackerNewsSearchTool(configuration: configuration, transport: transport)]
        case "reddit":
            return [RedditSearchTool(configuration: configuration, transport: transport)]
        case "jina", "jina_reader":
            return [JinaReaderTool(configuration: configuration, secret: secret, transport: transport)]
        case "apple_music":
            return [AppleMusicSearchTool(configuration: configuration, transport: transport)]
        case "brave", "brave_search":
            return [
                BraveSearchTool(configuration: configuration, secret: secret, transport: transport),
                ScopedRESTRequestTool(configuration: configuration, secret: secret, transport: transport)
            ]
        case "perplexity":
            return [
                PerplexityResearchTool(configuration: configuration, secret: secret, transport: transport),
                ScopedRESTRequestTool(configuration: configuration, secret: secret, transport: transport)
            ]
        case "tavily":
            return [
                TavilySearchTool(configuration: configuration, secret: secret, transport: transport),
                ScopedRESTRequestTool(configuration: configuration, secret: secret, transport: transport)
            ]
        case "exa":
            return [
                ExaSearchTool(configuration: configuration, secret: secret, transport: transport),
                ScopedRESTRequestTool(configuration: configuration, secret: secret, transport: transport)
            ]
        case "firecrawl":
            return [
                FirecrawlScrapeTool(configuration: configuration, secret: secret, transport: transport),
                ScopedRESTRequestTool(configuration: configuration, secret: secret, transport: transport)
            ]
        case "newsapi":
            return [
                NewsAPISearchTool(configuration: configuration, secret: secret, transport: transport),
                ScopedRESTRequestTool(configuration: configuration, secret: secret, transport: transport)
            ]
        default:
            return [ScopedRESTRequestTool(configuration: configuration, secret: secret, transport: transport)]
        }
    }
}

protocol BuiltinDescribedTool: AgentTool {
    var definition: ConnectorToolDefinition { get }
}

private struct NoopHTTPTransport: HTTPTransport {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse { HTTPResponse(status: 501) }
    func stream(_ request: HTTPRequest) async throws -> HTTPStreamResponse {
        HTTPStreamResponse(status: 501, headers: [:], body: AsyncThrowingStream { $0.finish() })
    }
}

// MARK: - Zero-Key Public Tools

private struct WikipediaSearchTool: BuiltinDescribedTool {
    let configuration: ConnectorConfiguration
    let transport: any HTTPTransport
    var definition: ConnectorToolDefinition {
        ConnectorToolDefinition(
            serverID: configuration.serverID, serverName: configuration.displayName, originalName: "search_articles",
            title: "Search Wikipedia", description: "Search Wikipedia articles by topic or keyword.",
            inputSchema: ["type": "object", "properties": ["query": ["type": "string", "description": "Search query"], "limit": ["type": "integer", "description": "Max results (1-10)"]], "required": ["query"]],
            readOnlyHint: true
        )
    }
    var name: String { definition.namespacedName }
    var spec: ToolSpec { ToolSpec(name: name, description: definition.description, parameters: definition.inputSchema) }
    var bringsOutsideContent: Bool { true }
    func runningSummary(for arguments: JSONValue) -> String { "Searching Wikipedia for \(arguments["query"]?.stringValue ?? "topic")…" }
    func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let query = try arguments.requiredString("query")
        let limit = min(max(arguments.optionalInt("limit") ?? 5, 1), 10)
        var comp = URLComponents(string: "https://en.wikipedia.org/w/rest.php/v1/search/page")!
        comp.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "limit", value: String(limit))]
        let res = try await transport.send(HTTPRequest(url: comp.url!, headers: ["Accept": "application/json", "User-Agent": "MAIPA-G/1.0"]))
        let text = String(res.text.prefix(12_000))
        return ToolOutput(forModel: text, summary: "Searched Wikipedia", detail: text)
    }
}

private struct WikipediaSummaryTool: BuiltinDescribedTool {
    let configuration: ConnectorConfiguration
    let transport: any HTTPTransport
    var definition: ConnectorToolDefinition {
        ConnectorToolDefinition(
            serverID: configuration.serverID, serverName: configuration.displayName, originalName: "read_summary",
            title: "Read Wikipedia summary", description: "Read the summary and canonical URL of a Wikipedia article by title.",
            inputSchema: ["type": "object", "properties": ["title": ["type": "string", "description": "Exact Wikipedia page title"]], "required": ["title"]],
            readOnlyHint: true
        )
    }
    var name: String { definition.namespacedName }
    var spec: ToolSpec { ToolSpec(name: name, description: definition.description, parameters: definition.inputSchema) }
    var bringsOutsideContent: Bool { true }
    func runningSummary(for arguments: JSONValue) -> String { "Reading Wikipedia: \(arguments["title"]?.stringValue ?? "")…" }
    func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let title = try arguments.requiredString("title").replacingOccurrences(of: " ", with: "_")
        let encoded = title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? title
        let url = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(encoded)")!
        let res = try await transport.send(HTTPRequest(url: url, headers: ["Accept": "application/json", "User-Agent": "MAIPA-G/1.0"]))
        let text = String(res.text.prefix(12_000))
        return ToolOutput(forModel: text, summary: "Read Wikipedia summary", detail: text)
    }
}

private struct ArXivSearchTool: BuiltinDescribedTool {
    let configuration: ConnectorConfiguration
    let transport: any HTTPTransport
    var definition: ConnectorToolDefinition {
        ConnectorToolDefinition(
            serverID: configuration.serverID, serverName: configuration.displayName, originalName: "search_papers",
            title: "Search arXiv papers", description: "Search scientific papers, authors, abstracts and PDF links on arXiv.org.",
            inputSchema: ["type": "object", "properties": ["query": ["type": "string", "description": "Search terms, author, or arXiv ID"], "max_results": ["type": "integer", "description": "Max papers (1-15)"]], "required": ["query"]],
            readOnlyHint: true
        )
    }
    var name: String { definition.namespacedName }
    var spec: ToolSpec { ToolSpec(name: name, description: definition.description, parameters: definition.inputSchema) }
    var bringsOutsideContent: Bool { true }
    func runningSummary(for arguments: JSONValue) -> String { "Searching arXiv for \(arguments["query"]?.stringValue ?? "papers")…" }
    func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let query = try arguments.requiredString("query")
        let maxResults = min(max(arguments.optionalInt("max_results") ?? 5, 1), 15)
        var comp = URLComponents(string: "https://export.arxiv.org/api/query")!
        comp.queryItems = [URLQueryItem(name: "search_query", value: "all:\(query)"), URLQueryItem(name: "start", value: "0"), URLQueryItem(name: "max_results", value: String(maxResults))]
        let res = try await transport.send(HTTPRequest(url: comp.url!, headers: ["User-Agent": "MAIPA-G/1.0"]))
        let text = String(res.text.prefix(16_000))
        return ToolOutput(forModel: text, summary: "Searched arXiv", detail: text)
    }
}

private struct HackerNewsSearchTool: BuiltinDescribedTool {
    let configuration: ConnectorConfiguration
    let transport: any HTTPTransport
    var definition: ConnectorToolDefinition {
        ConnectorToolDefinition(
            serverID: configuration.serverID, serverName: configuration.displayName, originalName: "search_stories",
            title: "Search Hacker News", description: "Search Hacker News stories and discussions or leave query empty for front-page stories.",
            inputSchema: ["type": "object", "properties": ["query": ["type": "string", "description": "Topic to search (omit or leave empty for front page)"]], "required": []],
            readOnlyHint: true
        )
    }
    var name: String { definition.namespacedName }
    var spec: ToolSpec { ToolSpec(name: name, description: definition.description, parameters: definition.inputSchema) }
    var bringsOutsideContent: Bool { true }
    func runningSummary(for arguments: JSONValue) -> String { "Checking Hacker News…" }
    func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let q = (arguments["query"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var comp = URLComponents(string: "https://hn.algolia.com/api/v1/search")!
        comp.queryItems = q.isEmpty
            ? [URLQueryItem(name: "tags", value: "front_page"), URLQueryItem(name: "hitsPerPage", value: "15")]
            : [URLQueryItem(name: "query", value: q), URLQueryItem(name: "tags", value: "story"), URLQueryItem(name: "hitsPerPage", value: "12")]
        let res = try await transport.send(HTTPRequest(url: comp.url!, headers: ["Accept": "application/json"]))
        let text = String(res.text.prefix(14_000))
        return ToolOutput(forModel: text, summary: q.isEmpty ? "Loaded Hacker News front page" : "Searched Hacker News", detail: text)
    }
}

private struct RedditSearchTool: BuiltinDescribedTool {
    let configuration: ConnectorConfiguration
    let transport: any HTTPTransport
    var definition: ConnectorToolDefinition {
        ConnectorToolDefinition(
            serverID: configuration.serverID, serverName: configuration.displayName, originalName: "search_posts",
            title: "Search Reddit", description: "Search public Reddit posts across all of Reddit or within a specific subreddit.",
            inputSchema: ["type": "object", "properties": ["query": ["type": "string", "description": "Search query"], "subreddit": ["type": "string", "description": "Optional subreddit name without r/"]], "required": ["query"]],
            readOnlyHint: true
        )
    }
    var name: String { definition.namespacedName }
    var spec: ToolSpec { ToolSpec(name: name, description: definition.description, parameters: definition.inputSchema) }
    var bringsOutsideContent: Bool { true }
    func runningSummary(for arguments: JSONValue) -> String { "Searching Reddit…" }
    func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let query = try arguments.requiredString("query")
        let sub = (arguments["subreddit"]?.stringValue ?? "").trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        let base = sub.isEmpty ? "https://www.reddit.com/search.json" : "https://www.reddit.com/r/\(sub)/search.json"
        var comp = URLComponents(string: base)!
        comp.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: "10"),
            URLQueryItem(name: "restrict_sr", value: sub.isEmpty ? "0" : "1")
        ]
        let res = try await transport.send(HTTPRequest(url: comp.url!, headers: ["Accept": "application/json", "User-Agent": "ios:dev.maipag.app:v1.0"]))
        let text = String(res.text.prefix(15_000))
        return ToolOutput(forModel: text, summary: "Searched Reddit", detail: text)
    }
}

private struct JinaReaderTool: BuiltinDescribedTool {
    let configuration: ConnectorConfiguration
    let secret: String?
    let transport: any HTTPTransport
    var definition: ConnectorToolDefinition {
        ConnectorToolDefinition(
            serverID: configuration.serverID, serverName: configuration.displayName, originalName: "extract_markdown",
            title: "Extract clean Markdown (Jina Reader)", description: "Convert any public HTTPS web page or PDF into clean Markdown via r.jina.ai.",
            inputSchema: ["type": "object", "properties": ["url": ["type": "string", "description": "Full https:// URL to read"]], "required": ["url"]],
            readOnlyHint: true
        )
    }
    var name: String { definition.namespacedName }
    var spec: ToolSpec { ToolSpec(name: name, description: definition.description, parameters: definition.inputSchema) }
    var bringsOutsideContent: Bool { true }
    func runningSummary(for arguments: JSONValue) -> String { "Reading page with Jina Reader…" }
    func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let raw = try arguments.requiredString("url").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let target = URL(string: raw), (try? OAuthURLPolicy.validate(target)) != nil else {
            throw ToolInputError("Jina Reader requires a public https:// URL.")
        }
        guard let readerURL = URL(string: "https://r.jina.ai/\(target.absoluteString)") else {
            throw ToolInputError("Invalid URL.")
        }
        var headers = ["Accept": "text/plain"]
        if let secret, !secret.isEmpty { headers["Authorization"] = "Bearer \(secret)" }
        let res = try await transport.send(HTTPRequest(url: readerURL, headers: headers))
        let text = String(res.text.prefix(24_000))
        return ToolOutput(forModel: text, summary: "Extracted Markdown via Jina Reader", detail: String(text.prefix(1_200)))
    }
}

private struct AppleMusicSearchTool: BuiltinDescribedTool {
    let configuration: ConnectorConfiguration
    let transport: any HTTPTransport
    var definition: ConnectorToolDefinition {
        ConnectorToolDefinition(
            serverID: configuration.serverID, serverName: configuration.displayName, originalName: "search_catalog",
            title: "Search Apple Music", description: "Search songs, albums, and artists in the Apple Music catalog and get direct Apple Music links.",
            inputSchema: ["type": "object", "properties": ["query": ["type": "string", "description": "Song, artist, or album"], "entity": ["type": "string", "description": "song, album, or musicArtist (default song)"]], "required": ["query"]],
            readOnlyHint: true
        )
    }
    var name: String { definition.namespacedName }
    var spec: ToolSpec { ToolSpec(name: name, description: definition.description, parameters: definition.inputSchema) }
    var bringsOutsideContent: Bool { true }
    func runningSummary(for arguments: JSONValue) -> String { "Searching Apple Music for \(arguments["query"]?.stringValue ?? "")…" }
    func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let query = try arguments.requiredString("query")
        let entity = arguments["entity"]?.stringValue ?? "song"
        var comp = URLComponents(string: "https://itunes.apple.com/search")!
        comp.queryItems = [URLQueryItem(name: "term", value: query), URLQueryItem(name: "media", value: "music"), URLQueryItem(name: "entity", value: entity), URLQueryItem(name: "limit", value: "10")]
        let res = try await transport.send(HTTPRequest(url: comp.url!, headers: ["Accept": "application/json"]))
        let text = String(res.text.prefix(14_000))
        return ToolOutput(forModel: text, summary: "Searched Apple Music", detail: text)
    }
}

// MARK: - Dedicated Search / Research Tools

private struct BraveSearchTool: BuiltinDescribedTool {
    let configuration: ConnectorConfiguration
    let secret: String?
    let transport: any HTTPTransport
    var definition: ConnectorToolDefinition {
        ConnectorToolDefinition(
            serverID: configuration.serverID, serverName: configuration.displayName, originalName: "web_search",
            title: "Brave Web Search", description: "Search the web via Brave Search API.",
            inputSchema: ["type": "object", "properties": ["query": ["type": "string", "description": "Search query"], "count": ["type": "integer", "description": "Results (1-15)"]], "required": ["query"]],
            readOnlyHint: true
        )
    }
    var name: String { definition.namespacedName }
    var spec: ToolSpec { ToolSpec(name: name, description: definition.description, parameters: definition.inputSchema) }
    var bringsOutsideContent: Bool { true }
    func runningSummary(for arguments: JSONValue) -> String { "Searching Brave for \(arguments["query"]?.stringValue ?? "")…" }
    func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        guard let secret, !secret.isEmpty else { throw ToolInputError("Add your Brave Search API key in Connectors → Brave Search.") }
        let q = try arguments.requiredString("query")
        let count = min(max(arguments.optionalInt("count") ?? 8, 1), 15)
        var comp = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")!
        comp.queryItems = [URLQueryItem(name: "q", value: q), URLQueryItem(name: "count", value: String(count))]
        let res = try await transport.send(HTTPRequest(url: comp.url!, headers: ["Accept": "application/json", "X-Subscription-Token": secret], followsRedirects: false))
        guard res.isSuccess else { throw ToolInputError("Brave Search returned HTTP \(res.status): \(res.text.prefix(300))") }
        let out = String(res.text.prefix(16_000))
        return ToolOutput(forModel: out, summary: "Searched Brave", detail: String(out.prefix(1_200)))
    }
}

private struct PerplexityResearchTool: BuiltinDescribedTool {
    let configuration: ConnectorConfiguration
    let secret: String?
    let transport: any HTTPTransport
    var definition: ConnectorToolDefinition {
        ConnectorToolDefinition(
            serverID: configuration.serverID, serverName: configuration.displayName, originalName: "research",
            title: "Perplexity Sonar Research", description: "Run grounded web research with citations using Perplexity Sonar.",
            inputSchema: ["type": "object", "properties": ["query": ["type": "string", "description": "Research question"], "deep": ["type": "boolean", "description": "Use sonar-pro when true (default false)"]], "required": ["query"]],
            readOnlyHint: true
        )
    }
    var name: String { definition.namespacedName }
    var spec: ToolSpec { ToolSpec(name: name, description: definition.description, parameters: definition.inputSchema) }
    var bringsOutsideContent: Bool { true }
    func runningSummary(for arguments: JSONValue) -> String { "Researching with Perplexity…" }
    func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        guard let secret, !secret.isEmpty else { throw ToolInputError("Add your Perplexity API key in Connectors → Perplexity.") }
        let query = try arguments.requiredString("query")
        let model = (arguments["deep"]?.boolValue == true) ? "sonar-pro" : "sonar"
        let body: JSONValue = ["model": .string(model), "messages": [.object(["role": "user", "content": .string(query)])]]
        var req = try HTTPRequest.json("POST", URL(string: "https://api.perplexity.ai/chat/completions")!, body: body, headers: ["Authorization": "Bearer \(secret)"])
        req.followsRedirects = false
        let res = try await transport.send(req)
        guard res.isSuccess else { throw ToolInputError("Perplexity returned HTTP \(res.status): \(res.text.prefix(300))") }
        let out = String(res.text.prefix(18_000))
        return ToolOutput(forModel: out, summary: "Researched via Perplexity", detail: String(out.prefix(1_200)))
    }
}

private struct TavilySearchTool: BuiltinDescribedTool {
    let configuration: ConnectorConfiguration
    let secret: String?
    let transport: any HTTPTransport
    var definition: ConnectorToolDefinition {
        ConnectorToolDefinition(
            serverID: configuration.serverID, serverName: configuration.displayName, originalName: "search",
            title: "Tavily Web Search", description: "Search the web with extracted snippets via Tavily.",
            inputSchema: ["type": "object", "properties": ["query": ["type": "string", "description": "Search query"]], "required": ["query"]],
            readOnlyHint: true
        )
    }
    var name: String { definition.namespacedName }
    var spec: ToolSpec { ToolSpec(name: name, description: definition.description, parameters: definition.inputSchema) }
    var bringsOutsideContent: Bool { true }
    func runningSummary(for arguments: JSONValue) -> String { "Searching Tavily…" }
    func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        guard let secret, !secret.isEmpty else { throw ToolInputError("Add your Tavily API key in Connectors → Tavily.") }
        let query = try arguments.requiredString("query")
        let body: JSONValue = ["query": .string(query), "search_depth": "advanced", "include_answer": true]
        var req = try HTTPRequest.json("POST", URL(string: "https://api.tavily.com/search")!, body: body, headers: ["Authorization": "Bearer \(secret)"])
        req.followsRedirects = false
        let res = try await transport.send(req)
        guard res.isSuccess else { throw ToolInputError("Tavily returned HTTP \(res.status): \(res.text.prefix(300))") }
        let out = String(res.text.prefix(16_000))
        return ToolOutput(forModel: out, summary: "Searched Tavily", detail: String(out.prefix(1_200)))
    }
}

private struct ExaSearchTool: BuiltinDescribedTool {
    let configuration: ConnectorConfiguration
    let secret: String?
    let transport: any HTTPTransport
    var definition: ConnectorToolDefinition {
        ConnectorToolDefinition(
            serverID: configuration.serverID, serverName: configuration.displayName, originalName: "search",
            title: "Exa Neural Search", description: "Semantic neural search across articles, papers, companies and code via Exa.",
            inputSchema: ["type": "object", "properties": ["query": ["type": "string", "description": "Semantic search query"], "num_results": ["type": "integer", "description": "Number of results (1-10)"]], "required": ["query"]],
            readOnlyHint: true
        )
    }
    var name: String { definition.namespacedName }
    var spec: ToolSpec { ToolSpec(name: name, description: definition.description, parameters: definition.inputSchema) }
    var bringsOutsideContent: Bool { true }
    func runningSummary(for arguments: JSONValue) -> String { "Searching Exa…" }
    func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        guard let secret, !secret.isEmpty else { throw ToolInputError("Add your Exa API key in Connectors → Exa.") }
        let query = try arguments.requiredString("query")
        let count = min(max(arguments.optionalInt("num_results") ?? 6, 1), 10)
        let body: JSONValue = ["query": .string(query), "numResults": .number(Double(count)), "contents": ["text": true]]
        var req = try HTTPRequest.json("POST", URL(string: "https://api.exa.ai/search")!, body: body, headers: ["x-api-key": secret])
        req.followsRedirects = false
        let res = try await transport.send(req)
        guard res.isSuccess else { throw ToolInputError("Exa returned HTTP \(res.status): \(res.text.prefix(300))") }
        let out = String(res.text.prefix(16_000))
        return ToolOutput(forModel: out, summary: "Searched Exa", detail: String(out.prefix(1_200)))
    }
}

private struct FirecrawlScrapeTool: BuiltinDescribedTool {
    let configuration: ConnectorConfiguration
    let secret: String?
    let transport: any HTTPTransport
    var definition: ConnectorToolDefinition {
        ConnectorToolDefinition(
            serverID: configuration.serverID, serverName: configuration.displayName, originalName: "scrape_url",
            title: "Scrape Page (Firecrawl)", description: "Scrape any web page into clean Markdown via Firecrawl.",
            inputSchema: ["type": "object", "properties": ["url": ["type": "string", "description": "Public https:// URL to scrape"]], "required": ["url"]],
            readOnlyHint: true
        )
    }
    var name: String { definition.namespacedName }
    var spec: ToolSpec { ToolSpec(name: name, description: definition.description, parameters: definition.inputSchema) }
    var bringsOutsideContent: Bool { true }
    func runningSummary(for arguments: JSONValue) -> String { "Scraping page with Firecrawl…" }
    func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        guard let secret, !secret.isEmpty else { throw ToolInputError("Add your Firecrawl API key in Connectors → Firecrawl.") }
        let url = try arguments.requiredString("url")
        let body: JSONValue = ["url": .string(url), "formats": ["markdown"]]
        var req = try HTTPRequest.json("POST", URL(string: "https://api.firecrawl.dev/v1/scrape")!, body: body, headers: ["Authorization": "Bearer \(secret)"])
        req.followsRedirects = false
        let res = try await transport.send(req)
        guard res.isSuccess else { throw ToolInputError("Firecrawl returned HTTP \(res.status): \(res.text.prefix(300))") }
        let out = String(res.text.prefix(20_000))
        return ToolOutput(forModel: out, summary: "Scraped page via Firecrawl", detail: String(out.prefix(1_200)))
    }
}

private struct NewsAPISearchTool: BuiltinDescribedTool {
    let configuration: ConnectorConfiguration
    let secret: String?
    let transport: any HTTPTransport
    var definition: ConnectorToolDefinition {
        ConnectorToolDefinition(
            serverID: configuration.serverID, serverName: configuration.displayName, originalName: "search_news",
            title: "Search NewsAPI", description: "Search global news articles and headlines via NewsAPI.org.",
            inputSchema: ["type": "object", "properties": ["query": ["type": "string", "description": "News topic or keyword"]], "required": ["query"]],
            readOnlyHint: true
        )
    }
    var name: String { definition.namespacedName }
    var spec: ToolSpec { ToolSpec(name: name, description: definition.description, parameters: definition.inputSchema) }
    var bringsOutsideContent: Bool { true }
    func runningSummary(for arguments: JSONValue) -> String { "Searching NewsAPI…" }
    func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        guard let secret, !secret.isEmpty else { throw ToolInputError("Add your NewsAPI key in Connectors → NewsAPI.") }
        let query = try arguments.requiredString("query")
        var comp = URLComponents(string: "https://newsapi.org/v2/everything")!
        comp.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "pageSize", value: "10"), URLQueryItem(name: "sortBy", value: "publishedAt")]
        let res = try await transport.send(HTTPRequest(url: comp.url!, headers: ["Accept": "application/json", "X-Api-Key": secret], followsRedirects: false))
        guard res.isSuccess else { throw ToolInputError("NewsAPI returned HTTP \(res.status): \(res.text.prefix(300))") }
        let out = String(res.text.prefix(16_000))
        return ToolOutput(forModel: out, summary: "Searched NewsAPI", detail: String(out.prefix(1_200)))
    }
}

// MARK: - Host-Pinned Authenticated REST Tool (Covers All Direct API Services Safely)

private struct ScopedRESTRequestTool: BuiltinDescribedTool {
    let configuration: ConnectorConfiguration
    let secret: String?
    let transport: any HTTPTransport

    var definition: ConnectorToolDefinition {
        let baseHint = effectiveBaseURLString
        return ConnectorToolDefinition(
            serverID: configuration.serverID,
            serverName: configuration.displayName,
            originalName: "api_request",
            title: "\(configuration.displayName) API request",
            description: "Call \(configuration.displayName)'s HTTPS API (pinned to `\(baseHint)`). Pass a relative `path` (e.g. `/projects` or `/messages`), HTTP `method` (`GET`, `POST`, `PUT`, `PATCH`, `DELETE`), optional `query` parameters, and optional JSON `body`.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "method": ["type": "string", "description": "HTTP method: GET (default), POST, PUT, PATCH, DELETE."],
                    "path": ["type": "string", "description": .string("Relative endpoint path appended to \(baseHint) (for example \"/me\" or \"/tasks\").")],
                    "query": ["type": "object", "description": "Optional query parameters as string key/value pairs."],
                    "body": ["type": "object", "description": "Optional JSON request body for POST/PUT/PATCH."]
                ],
                "required": ["path"]
            ]
        )
    }

    var name: String { definition.namespacedName }
    var spec: ToolSpec { ToolSpec(name: name, description: definition.description, parameters: definition.inputSchema) }
    var bringsOutsideContent: Bool { true }

    func runningSummary(for arguments: JSONValue) -> String {
        let m = (arguments["method"]?.stringValue ?? "GET").uppercased()
        let p = arguments["path"]?.stringValue ?? ""
        return "\(configuration.displayName): \(m) \(p)…"
    }

    func approvalRequest(for arguments: JSONValue) async -> ToolApprovalRequest? {
        let method = (arguments["method"]?.stringValue ?? "GET").uppercased()
        if method == "DELETE" {
            return ToolApprovalRequest(question: "Allow MAIPA-G to send DELETE \(arguments["path"]?.stringValue ?? "") to \(configuration.displayName)?", allowLabel: "Allow delete")
        }
        return nil
    }

    func approvalAfterOutsideContent(for arguments: JSONValue) async -> ToolApprovalRequest? {
        let method = (arguments["method"]?.stringValue ?? "GET").uppercased()
        guard method != "GET" && method != "HEAD" else { return nil }
        return ToolApprovalRequest(
            question: "MAIPA-G read outside content earlier in this turn and now wants to send \(method) \(arguments["path"]?.stringValue ?? "") to \(configuration.displayName). Allow it?",
            allowLabel: "Allow \(configuration.displayName)"
        )
    }

    private var effectiveBaseURLString: String {
        if let customInstance = configuration.launchValues["instance_url"] ?? configuration.launchValues["zone_url"],
           !customInstance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return customInstance.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let shop = configuration.launchValues["shop_domain"], !shop.isEmpty {
            let clean = shop.replacingOccurrences(of: "https://", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            return "https://\(clean)/admin/api/2024-10"
        }
        if let sub = configuration.launchValues["subdomain"], !sub.isEmpty {
            let clean = sub.trimmingCharacters(in: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-")).inverted)
            return "https://\(clean).zendesk.com/api/v2"
        }
        if let realm = configuration.launchValues["realm_id"], !realm.isEmpty,
           let base = configuration.endpoint?.absoluteString, base.contains("quickbooks.api.intuit.com") {
            return "\(base.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/\(realm)"
        }
        if let acct = configuration.launchValues["account_id"], !acct.isEmpty,
           let base = configuration.endpoint?.absoluteString, base.contains("basecampapi.com") {
            return "\(base.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/\(acct)"
        }
        return configuration.endpoint?.absoluteString ?? "https://api.example.com"
    }

    func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let method = (arguments["method"]?.stringValue ?? "GET").uppercased()
        let rawPath = try arguments.requiredString("path").trimmingCharacters(in: .whitespacesAndNewlines)
        let authStyle = RESTAuthStyle(rawValue: configuration.launchValues["auth_style"] ?? "bearer") ?? .bearer
        let authName = configuration.authHeaderName ?? configuration.launchValues["auth_name"] ?? "Authorization"

        var baseText = effectiveBaseURLString
        while baseText.hasSuffix("/") { baseText.removeLast() }
        if authStyle == .telegramBotPath {
            guard let secret, !secret.isEmpty else { throw ToolInputError("Add your Telegram Bot Token in Connectors → Telegram.") }
            baseText += "/bot\(secret)"
        }
        guard let baseURL = URL(string: baseText), (try? OAuthURLPolicy.validate(baseURL)) != nil,
              let pinnedHost = baseURL.host?.lowercased() else {
            throw ToolInputError("Connector base URL must be a public https:// address.")
        }

        let cleanRel = rawPath.hasPrefix("/") ? rawPath : "/" + rawPath
        guard !cleanRel.contains(".."), let combined = URL(string: baseText + cleanRel),
              combined.scheme?.lowercased() == "https",
              combined.host?.lowercased() == pinnedHost else {
            throw ToolInputError("Path must stay on \(pinnedHost).")
        }

        var comp = URLComponents(url: combined, resolvingAgainstBaseURL: false)!
        var items = comp.queryItems ?? []
        if let queryObj = arguments["query"]?.objectValue {
            for (k, v) in queryObj.sorted(by: { $0.key < $1.key }) {
                if let s = v.stringValue { items.append(URLQueryItem(name: k, value: s)) }
                else if let i = v.intValue { items.append(URLQueryItem(name: k, value: String(i))) }
                else if let b = v.boolValue { items.append(URLQueryItem(name: k, value: String(b))) }
            }
        }
        if let extraKey = configuration.launchValues["extra_key"],
           let extraVal = configuration.launchValues["extra_value"], !extraKey.isEmpty, !extraVal.isEmpty {
            if extraKey.hasPrefix("DD-") {
                // Added as header below
            } else if !["instance_url", "zone_url", "shop_domain", "subdomain", "realm_id", "account_id", "phone_number_id"].contains(extraKey) {
                items.append(URLQueryItem(name: extraKey, value: extraVal))
            }
        }
        if authStyle == .queryParam, let secret, !secret.isEmpty {
            items.append(URLQueryItem(name: authName, value: secret))
        }
        if !items.isEmpty { comp.queryItems = items }
        guard let finalURL = comp.url else { throw ToolInputError("Invalid request URL.") }

        var headers: [String: String] = ["Accept": "application/json", "User-Agent": "MAIPA-G/1.0"]
        if let secret, !secret.isEmpty {
            switch authStyle {
            case .bearer:
                headers["Authorization"] = secret.lowercased().hasPrefix("bearer ") ? secret : "Bearer \(secret)"
            case .header:
                headers[authName] = secret
            case .basicToken:
                headers["Authorization"] = "Basic \(Data(secret.utf8).base64EncodedString())"
            case .none, .queryParam, .telegramBotPath:
                break
            }
        }
        if let extraKey = configuration.launchValues["extra_key"], extraKey.hasPrefix("DD-"),
           let extraVal = configuration.launchValues["extra_value"], !extraVal.isEmpty {
            headers[extraKey] = extraVal
        }

        var bodyData: Data?
        if let bodyVal = arguments["body"], bodyVal != .null {
            headers["Content-Type"] = "application/json"
            bodyData = try JSONEncoder().encode(bodyVal)
        }
        // Never follow redirects when carrying credentials.
        let req = HTTPRequest(method: method, url: finalURL, headers: headers, body: bodyData, followsRedirects: false)
        let res = try await transport.send(req)
        let out = "HTTP \(res.status)\n" + String(res.text.prefix(18_000))
        if !res.isSuccess {
            throw ToolInputError("\(configuration.displayName) returned HTTP \(res.status): \(res.text.prefix(400))")
        }
        return ToolOutput(forModel: out, summary: "\(configuration.displayName) \(method) \(cleanRel)", detail: String(out.prefix(1_200)))
    }
}

// MARK: - Custom Webhooks Tool

public struct WebhookConnectorTool: AgentTool {
    public let configuration: ConnectorConfiguration
    private let secretValue: String?
    private let transport: any HTTPTransport

    public init(configuration: ConnectorConfiguration, secretValue: String?, transport: any HTTPTransport) {
        self.configuration = configuration
        self.secretValue = secretValue
        self.transport = transport
    }

    public var definition: ConnectorToolDefinition {
        ConnectorToolDefinition(
            serverID: configuration.serverID,
            serverName: configuration.displayName,
            originalName: "trigger_webhook",
            title: "Trigger \(configuration.displayName)",
            description: "Send a JSON payload to the configured HTTPS webhook (\(configuration.webhookMethod ?? "POST") \(configuration.endpoint?.host ?? "")).",
            inputSchema: [
                "type": "object",
                "properties": [
                    "payload": ["type": "object", "description": "JSON object payload to send to the webhook."],
                    "query": ["type": "object", "description": "Optional URL query parameters."]
                ],
                "required": ["payload"]
            ]
        )
    }

    public var name: String { definition.namespacedName }
    public var spec: ToolSpec { ToolSpec(name: name, description: definition.description, parameters: definition.inputSchema) }
    public var bringsOutsideContent: Bool { true }

    public func runningSummary(for arguments: JSONValue) -> String { "Triggering webhook \(configuration.displayName)…" }

    public func approvalAfterOutsideContent(for arguments: JSONValue) async -> ToolApprovalRequest? {
        ToolApprovalRequest(
            question: "MAIPA-G read outside content earlier in this turn and now wants to trigger your webhook \"\(configuration.displayName)\". Allow it?",
            allowLabel: "Trigger webhook"
        )
    }

    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        guard let endpoint = configuration.endpoint, (try? OAuthURLPolicy.validate(endpoint)) != nil else {
            throw ToolInputError("Webhook URL must be a public https:// address.")
        }
        let method = (configuration.webhookMethod ?? "POST").uppercased()
        var comp = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        if let q = arguments["query"]?.objectValue, !q.isEmpty {
            var items = comp.queryItems ?? []
            for (k, v) in q.sorted(by: { $0.key < $1.key }) {
                if let s = v.stringValue { items.append(URLQueryItem(name: k, value: s)) }
            }
            comp.queryItems = items
        }
        var headers = ["Content-Type": "application/json", "Accept": "application/json, text/plain;q=0.8"]
        if let secretValue, !secretValue.isEmpty {
            let headerName = (configuration.authHeaderName?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "Authorization"
            if headerName.lowercased() == "authorization", !secretValue.lowercased().hasPrefix("bearer ") {
                headers[headerName] = "Bearer \(secretValue)"
            } else {
                headers[headerName] = secretValue
            }
        }
        let payload = arguments["payload"] ?? .object([:])
        let body = method == "GET" ? nil : (try JSONEncoder().encode(payload))
        let res = try await transport.send(HTTPRequest(method: method, url: comp.url ?? endpoint, headers: headers, body: body, followsRedirects: false))
        guard res.isSuccess else {
            throw ToolInputError("Webhook returned HTTP \(res.status): \(res.text.prefix(300))")
        }
        let out = "HTTP \(res.status)\n" + String(res.text.prefix(8_000))
        return ToolOutput(forModel: out, summary: "Triggered \(configuration.displayName)", detail: out)
    }
}

// MARK: - Live Chat Stdio MCP Bridge via Connected Linux Computer (`mcp-maipa-g`)

public struct StdioComputerBridgeTool: AgentTool {
    public let configuration: ConnectorConfiguration
    public let package: RegistryServer.Package
    private let secrets: [String: String]
    private let computer: ComputerControl

    public init(configuration: ConnectorConfiguration, package: RegistryServer.Package, secrets: [String: String], computer: ComputerControl) {
        self.configuration = configuration
        self.package = package
        self.secrets = secrets
        self.computer = computer
    }

    public var name: String {
        ConnectorToolDefinition.namespace(server: configuration.displayName, tool: "call")
    }

    public var spec: ToolSpec {
        ToolSpec(
            name: name,
            description: "Call the \(configuration.displayName) MCP server running on the connected Linux computer. Pass `method: \"tools/list\"` first to inspect available tools, or `method: \"tools/call\"` with `params: {\"name\": \"...\", \"arguments\": {...}}`.",
            parameters: [
                "type": "object",
                "properties": [
                    "method": ["type": "string", "description": "JSON-RPC method: \"tools/list\" or \"tools/call\"."],
                    "params": ["type": "object", "description": "Method parameters (for tools/call: {\"name\": \"tool_name\", \"arguments\": {...}})."]
                ],
                "required": ["method"]
            ]
        )
    }

    public var bringsOutsideContent: Bool { true }

    public func runningSummary(for arguments: JSONValue) -> String {
        let inner = arguments["params"]?["name"]?.stringValue ?? arguments["method"]?.stringValue ?? "call"
        return "\(configuration.displayName): \(inner)…"
    }

    public func approvalRequest(for arguments: JSONValue) async -> ToolApprovalRequest? {
        if let method = arguments["method"]?.stringValue, method == "tools/call",
           let toolName = arguments["params"]?["name"]?.stringValue {
            let def = ConnectorToolDefinition(serverID: configuration.serverID, serverName: configuration.displayName, originalName: toolName)
            let innerArgs = arguments["params"]?["arguments"] ?? .object([:])
            return ConnectorActionPolicy.approval(for: def, arguments: innerArgs)
        }
        return nil
    }

    public func approvalAfterOutsideContent(for arguments: JSONValue) async -> ToolApprovalRequest? {
        StdioMCPTool.approval(serverID: configuration.displayName, arguments: arguments)
    }

    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let method = try arguments.requiredString("method")
        guard method == "tools/list" || method == "tools/call" else {
            throw ToolInputError("Only tools/list and tools/call are supported.")
        }
        let launcher: [String]
        switch package.registryType.lowercased() {
        case "npm": launcher = ["npx", "-y", package.identifier]
        case "pypi": launcher = ["uvx", package.identifier]
        default: throw ToolInputError("Unsupported MCP package type \(package.registryType).")
        }
        var envMap = configuration.launchValues
        for (k, v) in secrets where !v.isEmpty { envMap[k] = v }

        let rpcPayload: JSONValue = [
            "jsonrpc": "2.0",
            "id": 2,
            "method": .string(method),
            "params": arguments["params"] ?? .object([:])
        ]
        let payloadB64 = try JSONEncoder().encode(rpcPayload).base64EncodedString()
        let cmdB64 = try JSONEncoder().encode(launcher).base64EncodedString()
        let envB64 = try JSONEncoder().encode(envMap).base64EncodedString()

        let script = """
        . "$HOME/.maipa-g/env.sh" 2>/dev/null || true
        python3 - '\(cmdB64)' '\(envB64)' '\(payloadB64)' <<'PY'
        import base64, json, os, subprocess, sys
        cmd = json.loads(base64.b64decode(sys.argv[1]).decode())
        extra_env = json.loads(base64.b64decode(sys.argv[2]).decode())
        req = json.loads(base64.b64decode(sys.argv[3]).decode())
        env = dict(os.environ)
        for k, v in extra_env.items():
            if isinstance(k, str) and isinstance(v, str):
                env[k] = v
        init = {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "MAIPA-G", "version": "1.0"}}}
        notif = {"jsonrpc": "2.0", "method": "notifications/initialized"}
        stdin_data = (json.dumps(init) + "\\n" + json.dumps(notif) + "\\n" + json.dumps(req) + "\\n").encode()
        p = subprocess.run(cmd, input=stdin_data, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, timeout=45)
        for line in p.stdout.decode("utf-8", errors="replace").splitlines():
            line = line.strip()
            if not line.startswith("{"): continue
            try:
                msg = json.loads(line)
                if msg.get("id") == 2:
                    print(json.dumps(msg.get("result", msg), ensure_ascii=False)[:16000])
                    sys.exit(0)
            except Exception:
                pass
        sys.stdout.write((p.stdout.decode("utf-8", errors="replace") + "\\n" + p.stderr.decode("utf-8", errors="replace"))[:4000])
        PY
        """
        let rawOut = try await computer.run(script)
        let trimmed = String(rawOut.prefix(16_000))
        return ToolOutput(forModel: trimmed, summary: "Called \(configuration.displayName)", detail: String(trimmed.prefix(1_200)))
    }
}
