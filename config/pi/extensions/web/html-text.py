"""Bounded HTML -> readable text. No networking, scripting, or external entities."""
import re
import sys
from html.parser import HTMLParser
from urllib.parse import urljoin, urlsplit


class Text(HTMLParser):
    hidden_tags = {"script", "style", "noscript", "template", "svg", "head"}
    blocks = {"p", "div", "section", "article", "header", "footer", "nav", "main",
              "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "pre",
              "blockquote", "br", "hr", "tr", "table"}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.hidden = []
        self.parts = []
        self.links = []

    def handle_starttag(self, tag, attrs):
        if tag in self.hidden_tags:
            self.hidden.append(tag)
        if self.hidden:
            return
        if tag == "a":
            href = dict(attrs).get("href", "")
            url = urljoin(sys.argv[1] if len(sys.argv) > 1 else "", href)
            parsed = urlsplit(url)
            self.links.append(url if href and len(url) <= 4096 and parsed.scheme in {"http", "https"}
                              and not parsed.username and not parsed.password else "")
        if tag in self.blocks:
            self.parts.append("\n")
        if tag == "li":
            self.parts.append("- ")
        if tag in {"td", "th"}:
            self.parts.append(" | ")

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        self.handle_endtag(tag)

    def handle_endtag(self, tag):
        if tag in self.hidden:
            # Malformed markup stays conservatively hidden until its parent closes.
            closing = len(self.hidden) - 1 - self.hidden[::-1].index(tag)
            self.hidden = self.hidden[:closing]
            return
        if not self.hidden and tag == "a" and self.links:
            url = self.links.pop()
            if url:
                self.parts.append(" (" + url + ")")
        if not self.hidden and tag in self.blocks:
            self.parts.append("\n")

    def handle_data(self, data):
        if not self.hidden:
            self.parts.append(data)


parser = Text()
parser.feed(sys.stdin.read(2 * 1024 * 1024 + 1))
parser.close()
text = "".join(parser.parts)
text = re.sub(r"[^\S\n]+", " ", text)
text = re.sub(r" *\n *", "\n", text)
text = re.sub(r"\n{3,}", "\n\n", text)
sys.stdout.write(text.strip())