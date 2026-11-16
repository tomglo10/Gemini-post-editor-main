# Project Instructions: Aging Health (`aginghealth.website`)

You are assisting Tommy T. Douglas with the custom Blogger Layout v3 (`b:layoutsversion='3'`) XML template (`TDMag` style), stylesheets, and client-side JavaScript modules for `aginghealth.website`.

Combine **Modern Web Guidance** (Baseline web platform APIs, native HTML/CSS, zero unnecessary dependencies) with strict **Blogger XHTML/XML parser compatibility**.

---

## 1. Strict Blogger XHTML & XML Parser Rules (Critical)
Blogger validates the entire theme as strict XML before saving. Never output raw HTML5 shortcuts that break XML parsing:
- **Self-Closing Void Tags:** Every void tag MUST be self-closed (`<meta .../>`, `<link .../>`, `<br/>`, `<hr/>`, `<img .../>`, `<input .../>`).
- **Boolean Attributes:** Never write bare attributes like `async`, `defer`, or `disabled`. Always use XML attribute-value pairs (`async='async'`, `defer='defer'`, `disabled='disabled'`).
- **CDATA Wrapping for JS & CSS:** Always wrap `<script>` and `<b:skin>` contents in `//<![CDATA[ ... //]]>` or `<![CDATA[ ... ]]>` so operators like `&&`, `<`, `>`, and `&` do not trigger XML entity parsing errors.
- **Escaped Entities in Text & JSON-LD:** Outside `CDATA` blocks, escape `&` as `&amp;`. Inside static `<script type='application/ld+json'>` blocks, use Blogger's `.jsonEscaped` modifier (e.g., `<data:post.title.jsonEscaped/>`) and wrap arithmetic in `<b:eval expr='...'/>` (never write `<data:i/> + 2`).
- **Blogger Layout v3 Expressions:** Use `data:view.*` (`data:view.isPost`, `data:view.isPage`, `data:view.isHomepage`, `data:view.url.canonical`, `data:view.featuredImage`) rather than deprecated v2 `data:blog.url.canonical` tags.

---

## 2. Canonical, SEO, AEO & GEO Architecture
- **Single Canonical Source:** Rely on `<b:include data='blog' name='all-head-content'/>` for `<link rel='canonical'/>`. Never add a duplicate manual canonical tag or append `?m=1` to internal links, sitemaps, or JSON-LD `@id` URLs.
- **Scoped Robots Directives:** Only output `index,follow` meta tags inside `<b:if cond='data:view.isPost or data:view.isPage or data:view.isHomepage'>` so archive/label pages do not conflict with Blogger's built-in `noindex` headers.
- **Structured Data (`@graph`):** Maintain clean Schema.org JSON-LD (`MedicalWebPage`, `Article`, `BreadcrumbList`, `FAQPage`, `DefinedTermSet` / `DefinedTerm` linked to `https://www.aginghealth.website/p/glossary.html#glossary`) attributed to author `Tommy T. Douglas`.

---

## 3. Modern Web Platform & CSS Standards
- **Baseline CSS Over JS:** Prefer native CSS Grid, Flexbox, `clamp()`, `:has()`, `:focus-visible`, `scroll-margin-top`, and `@media (prefers-reduced-motion: reduce)` instead of JavaScript layout calculations.
- **Native Interactive Elements:** Use native `<details>`/`<summary>` for accordions/FAQs and `popover` or `<dialog>` where appropriate rather than custom ARIA-heavy toggle scripts.
- **Theme Tokens & Dark Mode:** Use CSS custom properties (`--bg`, `--text`, `--primary`, `--surface`, `--border`, `--nav-height`) and support `[data-theme="dark"]` / `body.dark-mode` overrides.
- **Core Web Vitals (CLS & LCP):** Reserve explicit dimensions or `aspect-ratio` on images, skeleton placeholders, and dynamic containers (Table of Contents, Related Posts) to keep Cumulative Layout Shift (CLS) near `0`.

---

## 4. Accessibility & Senior-Friendly Design
- **Typography & Contrast:** Maintain readable base font sizes (`clamp(1.25rem, 1.35vw, 1.45rem)`), generous line height (`1.7`–`1.85`), system font stacks (`var(--font-sans)`), and WCAG AA+ contrast in both light and dark modes.
- **Keyboard & Screen-Reader Support:** Preserve visible `:focus-visible` outlines, semantic landmarks (`<header>`, `<nav>`, `<main>`, `<aside>`, `<footer>`), and ARIA attributes.

---

## 5. Glossary & Script Architecture
- **Unified Footer Modules:** Consolidate runtime scripts cleanly using `async`/`await`, `Promise`-based `fetch()`, `TreeWalker` DOM traversal, and `localStorage` caching where appropriate.
- **Glossary Exclusions:** Never auto-link terms inside headings (`h1`–`h6`), existing `<a>` tags, `<button>`, `<code>`, `<pre>`, `.sidebar`, `.breadcrumbs`, or any element marked with `data-no-glossary`.