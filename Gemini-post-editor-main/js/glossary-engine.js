(function () {
  "use strict";

  var DATA_URL = "https://cdn.jsdelivr.net/gh/tomglo10/Gemini-post-editor-main@main/Gemini-post-editor-main/glossary-data.json";
  var GLOSSARY_PAGE = "https://www.aginghealth.website/p/glossary.html";
  var CACHE_KEY = "ah_glossary_cache_v1";

  function escapeRegex(str) {
    return str.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  }

  function slugify(str) {
    return str.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
  }

  function normalizeTerms(raw) {
    var list = Array.isArray(raw) ? raw : (raw && Array.isArray(raw.terms) ? raw.terms : []);
    return list
      .map(function (item) {
        if (typeof item === "string") {
          return { term: item, definition: "", slug: slugify(item) };
        }
        var name = item.term || item.name || item.title || "";
        return {
          term: name,
          definition: item.definition || item.description || item.summary || "",
          slug: item.slug || item.id || slugify(name)
        };
      })
      .filter(function (item) { return item.term && item.term.length >= 3; })
      .sort(function (a, b) { return b.term.length - a.term.length; });
  }

  async function loadTerms() {
    try {
      var cached = sessionStorage.getItem(CACHE_KEY);
      if (cached) {
        return normalizeTerms(JSON.parse(cached));
      }
    } catch (e) {}

    var response = await fetch(DATA_URL, { cache: "default" });
    if (!response.ok) return [];
    var json = await response.json();
    try {
      sessionStorage.setItem(CACHE_KEY, JSON.stringify(json));
    } catch (e) {}
    return normalizeTerms(json);
  }

  function shouldSkipNode(node) {
    var parent = node.parentElement;
    if (!parent) return true;
    return Boolean(
      parent.closest(
        "a, button, script, style, textarea, input, select, summary, dt, h1, h2, h3, h4, h5, h6, .ah-article-glossary, .ah-faq-section, .ah-no-autolink"
      )
    );
  }

  function linkTermsInContainer(container, terms) {
    if (!container || !terms.length) return;

    var linkedOnce = Object.create(null);
    var pattern = new RegExp(
      "\\b(" + terms.map(function (t) { return escapeRegex(t.term); }).join("|") + ")\\b",
      "i"
    );

    var termMap = Object.create(null);
    terms.forEach(function (t) {
      termMap[t.term.toLowerCase()] = t;
    });

    var walker = document.createTreeWalker(container, NodeFilter.SHOW_TEXT, null);
    var textNodes = [];
    var current;
    while ((current = walker.nextNode())) {
      if (!shouldSkipNode(current) && pattern.test(current.nodeValue)) {
        textNodes.push(current);
      }
    }

    textNodes.forEach(function (node) {
      var text = node.nodeValue;
      var match = pattern.exec(text);
      if (!match) return;

      var matchedWord = match[0];
      var key = matchedWord.toLowerCase();
      if (linkedOnce[key]) return;

      var entry = termMap[key];
      if (!entry) return;

      linkedOnce[key] = true;

      var before = document.createTextNode(text.slice(0, match.index));
      var after = document.createTextNode(text.slice(match.index + matchedWord.length));

      var link = document.createElement("a");
      var localTarget = document.getElementById("term-" + entry.slug);
      link.href = localTarget ? "#term-" + entry.slug : GLOSSARY_PAGE + "#term-" + entry.slug;
      link.textContent = matchedWord;
      link.className = "ah-glossary-autolink";
      link.style.cssText = "color:#0369a1;text-decoration:underline dotted;text-underline-offset:3px;";
      if (entry.definition) {
        link.title = entry.term + ": " + entry.definition;
      }

      var frag = document.createDocumentFragment();
      frag.appendChild(before);
      frag.appendChild(link);
      frag.appendChild(after);
      node.parentNode.replaceChild(frag, node);
    });
  }

  async function init() {
    var postBody = document.querySelector(".post-body, .entry-content, article");
    if (!postBody) return;
    try {
      var terms = await loadTerms();
      linkTermsInContainer(postBody, terms);
    } catch (err) {
      console.warn("Aging Health glossary engine skipped:", err);
    }
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();