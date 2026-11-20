# Aging Health — Local Publishing & SEO Automation Pipeline

Local VS Code and PowerShell publishing workspace for **[Aging Health](https://www.aginghealth.website)** (authored by Tommy T. Douglas). This repository streamlines offline HTML drafting, dark/light previewing, JSON-LD structured data compilation, automated internal link discovery across 428+ live Blogger posts, sitemap auditing, and GitHub backups.

---

## Workspace Folder Structure

```text
Gemini-post-editor-main-main/
├── .vscode/
│   ├── tasks.json                     # One-click VS Code tasks & draftPicker dropdown
│   └── *.code-snippets                # Custom HTML & JSON-LD snippets (ah-medpage, ah-faq, etc.)
├── posts/                             # Active HTML article drafts (e.g., wisdom-aging-brain-cognitive-shifts.html)
├── scripts/
│   ├── generate-keyword-map.ps1       # Paginates Blogger summary feed into keyword-map.json
│   ├── suggest-internal-links.ps1     # Scores draft HTML against live posts & outputs <a> tags
│   ├── audit-sitemap.ps1              # Validates HTTP 200 status, canonicals, and Bing sync
│   └── keyword-map.json               # Local searchable index of all live Aging Health posts
├── build-blogger-post.ps1             # Compiles draft HTML & generates JSON-LD for Blogger
├── ah-preview.html                    # Local dark/light mode preview wrapper for Live Server
└── README.md                          # Workspace documentation
```

---

## VS Code Tasks (`.vscode/tasks.json`)

Trigger any task from the Command Palette (**Ctrl+Shift+P** → `Tasks: Run Task`) or use its assigned hotkey:

| Task Label | Shortcut / Trigger | Behavior |
| :--- | :--- | :--- |
| **Build Blogger Post** | `Ctrl+Shift+B` *(with draft tab active)* | Runs `build-blogger-post.ps1` on `${file}`, compiles Blogger-ready HTML, and generates `FAQPage` and `DefinedTermSet` JSON-LD schemas. |
| **Suggest Internal Links for Current Draft** | `Ctrl+Shift+P` → `Tasks: Run Task` | Opens the **`draftPicker`** dropdown so you can auto-scan the newest draft in `posts/`, browse all HTML files in a filterable window, or select a pinned draft. |
| **Audit & Sync Sitemap** | `Ctrl+Shift+P` → `Tasks: Run Task` | Audits every URL in `sitemap.xml` for `HTTP 200` status and canonical alignment, cross-checks `scripts/keyword-map.json`, and pings Bing Webmaster Tools. |
| **Refresh Local Keyword Map** | `Ctrl+Shift+P` → `Tasks: Run Task` | Fetches all published post titles, URLs, slugs, and labels from Blogger's summary feed and updates `scripts/keyword-map.json`. |

### Using the `draftPicker` Dropdown
When you launch **Suggest Internal Links for Current Draft**, VS Code prompts you with three modes:
1. **Newest Draft in posts/ (Auto-Detect):** Press **Enter** immediately to scan your most recently edited `.html` draft (works even when the terminal panel has focus).
2. **Browse All HTML Files in posts/ (Live Window):** Opens a searchable Windows grid (`Out-GridView`) listing every `.html` draft in `posts/` sorted by last modified date.
3. **Pinned Drafts:** Direct entries configured in `.vscode/tasks.json` for long-term articles you update regularly.

---

## PowerShell Scripts Reference

### 1. `scripts/generate-keyword-map.ps1`
Paginates through `https://www.aginghealth.website/feeds/posts/summary` (avoiding Blogger's full-body byte-size truncation) and exports a deduplicated JSON catalog to `scripts/keyword-map.json`.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\generate-keyword-map.ps1
```

### 2. `scripts/suggest-internal-links.ps1`
Strips HTML/script tags, skips URLs already linked in your draft, scores candidate posts by exact phrase matches, H2/H3 heading overlap, and topic keywords, and prints ranked `<a href="...">` snippets.

```powershell
# Auto-detect newest draft in posts\
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\suggest-internal-links.ps1

# Target a specific draft file and return top 15 matches
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\suggest-internal-links.ps1 -DraftPath .\posts\wisdom-aging-brain-cognitive-shifts.html -Top 15
```

### 3. `scripts/audit-sitemap.ps1`
Verifies live `sitemap.xml` accessibility, checks canonical URLs, confirms local `keyword-map.json` coverage, and submits updates to Bing when `-PingBing` is passed.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\audit-sitemap.ps1 -PingBing
```

### 4. `build-blogger-post.ps1`
Transforms a clean HTML draft in `posts/` into production Blogger markup with consolidated Schema.org JSON-LD blocks (`MedicalWebPage`, `Article`, `FAQPage`, `DefinedTermSet`).

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\build-blogger-post.ps1 .\posts\wisdom-aging-brain-cognitive-shifts.html
```

---

## Standard Publishing Workflow

1. **Draft & Structure:** Create a new `.html` file in `posts/` using your custom VS Code snippets (`ah-medpage`, `ah-article`, `ah-takeaways`, `ah-faq`, `ah-glossary`, `ah-term`, `ah-case`, `ah-sources`).
2. **Preview Locally:** Open the draft with VS Code **Live Server** (or `ah-preview.html`) to verify Grade 7–9 readability, responsive tables, and dark/light theme contrast.
3. **Add Internal Links:** Run **Suggest Internal Links for Current Draft**, copy 2–4 relevant `<a href="...">` suggestions, and weave them naturally into your draft prose.
4. **Compile & Publish:** With the draft tab focused, press **Ctrl+Shift+B** (`Build Blogger Post`) and paste the compiled HTML into Blogger's **HTML view**.
5. **Sync Index & Back Up:** Once live on `aginghealth.website`, run **Refresh Local Keyword Map** followed by **Audit & Sync Sitemap**, then push your workspace changes to GitHub.

---

## GitHub Backup Commands

Repository: `https://github.com/tomglo10/Gemini-post-editor-main.git`

```powershell
Set-Location "C:\Users\tomgl\OneDrive\Documents\Gemini-post-editor-main\Gemini-post-editor-main-main"
git status -s
git add .
git commit -m "Update Aging Health drafts, scripts, and keyword map"
git push
```