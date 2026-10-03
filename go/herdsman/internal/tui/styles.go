package tui

import (
	"fmt"
	"github.com/brucenunk/home-config/go/herdsman/internal/tui/themes"
	"github.com/charmbracelet/bubbles/help"
	"github.com/charmbracelet/bubbles/list"
	"github.com/charmbracelet/bubbles/textinput"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
	"io"
	"strings"
	"unicode/utf8"
)

type styles struct {
	text, muted, title, selected, match, error lipgloss.Style
	filenameSecondary, filenameMuted           lipgloss.Style
}

func newStyles(c themes.Colors) styles {
	if c == (themes.Colors{}) {
		// No palette: use the terminal's own foreground/background, retaining
		// emphasis and selection markers without hard-coded fallback colors.
		return styles{
			text: lipgloss.NewStyle(), muted: lipgloss.NewStyle().Faint(true),
			title:    lipgloss.NewStyle().Bold(true),
			selected: lipgloss.NewStyle().Reverse(true).Bold(true),
			match:    lipgloss.NewStyle().Underline(true),
			error:    lipgloss.NewStyle().Bold(true),
		}
	}
	return styles{
		text:  lipgloss.NewStyle().Foreground(lipgloss.Color(c.Text)),
		muted: lipgloss.NewStyle().Foreground(lipgloss.Color(c.Muted)),
		title: lipgloss.NewStyle().Foreground(lipgloss.Color(c.Accent)).Bold(true),
		selected: lipgloss.NewStyle().Foreground(lipgloss.Color(c.SelectionText)).
			Background(lipgloss.Color(c.SelectionBackground)),
		filenameSecondary: lipgloss.NewStyle().Foreground(lipgloss.Color(c.FilenameSecondary)),
		filenameMuted:     lipgloss.NewStyle().Foreground(lipgloss.Color(c.FilenameMuted)),
		match:             lipgloss.NewStyle().Foreground(lipgloss.Color(c.Match)).Underline(true),
		error:             lipgloss.NewStyle().Foreground(lipgloss.Color(c.Error)),
	}
}

func (s styles) items() list.DefaultItemStyles {
	normal := s.text.PaddingLeft(2)
	selected := s.selected.Border(lipgloss.NormalBorder(), false, false, false, true).
		BorderForeground(s.title.GetForeground()).PaddingLeft(1)
	return list.DefaultItemStyles{
		NormalTitle: normal, NormalDesc: s.muted.PaddingLeft(2),
		SelectedTitle: selected, SelectedDesc: selected,
		DimmedTitle: s.muted.PaddingLeft(2), DimmedDesc: s.muted.PaddingLeft(2),
		FilterMatch: s.match,
	}
}

func (s styles) input(input *textinput.Model) {
	input.PromptStyle = s.title
	input.TextStyle = s.text
	input.PlaceholderStyle = s.muted
	input.Cursor.Style = s.title
}

func (s styles) list(l *list.Model) {
	// Preserve Bubbles' layout while replacing every default color.
	l.Styles.Title = s.title.Padding(0, 1)
	l.Styles.Spinner = s.title
	l.Styles.FilterPrompt = s.title
	l.Styles.FilterCursor = s.title
	l.Styles.DefaultFilterCharacterMatch = s.match
	l.Styles.StatusBar = s.muted.Padding(0, 0, 1, 2)
	l.Styles.StatusEmpty = s.muted
	l.Styles.StatusBarActiveFilter = s.text
	l.Styles.StatusBarFilterCount = s.muted
	l.Styles.NoItems = s.muted
	l.Styles.ActivePaginationDot = s.title.SetString("•")
	l.Styles.InactivePaginationDot = s.muted.SetString("•")
	// Bubbles snapshots these rendered strings in list.New.
	l.Paginator.ActiveDot = l.Styles.ActivePaginationDot.String()
	l.Paginator.InactiveDot = l.Styles.InactivePaginationDot.String()
	l.Styles.ArabicPagination = s.muted
	l.Styles.DividerDot = s.muted.SetString(" • ")
	l.Help.Styles = help.Styles{
		Ellipsis: s.muted,
		ShortKey: s.text, ShortDesc: s.muted, ShortSeparator: s.muted,
		FullKey: s.text, FullDesc: s.muted, FullSeparator: s.muted,
	}
	s.input(&l.FilterInput)
}

// choiceDelegate retains the standard list behavior but explicitly overrides
// the match foreground. Inherit alone preserves the row's existing foreground.
type choiceDelegate struct {
	list.DefaultDelegate
	unselected bool
}

func (d choiceDelegate) Render(w io.Writer, m list.Model, index int, item list.Item) {
	style := d.Styles.NormalTitle
	if m.FilterState() == list.Filtering && m.FilterValue() == "" {
		style = d.Styles.DimmedTitle
	} else if !d.unselected && index == m.Index() && m.FilterState() != list.Filtering {
		style = d.Styles.SelectedTitle
	}
	var matches []int
	if m.FilterState() != list.Unfiltered {
		matches = m.MatchesForItem(index)
	}
	renderTitle(w, item.(list.DefaultItem).Title(), matches, style, d.Styles.FilterMatch, m.Width())
}

func renderTitle(w io.Writer, title string, matches []int, style, match lipgloss.Style, width int) {
	renderFilenameTitle(w, title, matches, style, match, nil, width)
}

func renderFilenameTitle(w io.Writer, title string, matches []int, style, match lipgloss.Style, parts []lipgloss.Style, width int) {
	contentWidth := width - style.GetHorizontalFrameSize()
	if contentWidth <= 0 {
		return
	}
	original := title
	// Bubbles forwards sahilm/fuzzy's byte offsets. Lip Gloss and filename
	// parts use rune indexes, so convert before truncating the original text.
	runeMatches := make([]int, 0, len(matches))
	for _, index := range matches {
		if index >= 0 && index < len(original) && utf8.RuneStart(original[index]) {
			runeMatches = append(runeMatches, utf8.RuneCountInString(original[:index]))
		}
	}
	title = ansi.Truncate(title, contentWidth, "…")
	base := style.Inline(true)
	if parts == nil {
		matched := base.Inherit(match).Foreground(match.GetForeground())
		title = lipgloss.StyleRunes(title, runeMatches, matched, base)
	} else {
		matched := make(map[int]bool, len(matches))
		for _, index := range runeMatches {
			matched[index] = true
		}
		var rendered strings.Builder
		remaining, state, index := title, -1, 0
		for remaining != "" {
			cluster, rest, _, nextState := ansi.FirstGraphemeCluster(remaining, state)
			count := utf8.RuneCountInString(cluster)
			part := base
			if index < len(parts) && !(title != original && rest == "") {
				part = parts[index].Inherit(base)
			}
			// Highlight the whole grapheme if any of
			// its runes match, never inserting escapes inside an emoji/accent.
			for i := index; i < index+count; i++ {
				if matched[i] {
					part = part.Inherit(match).Foreground(match.GetForeground())
					break
				}
			}
			if part.GetUnderline() {
				// Lip Gloss's underline renderer styles individual runes even
				// within a cluster. Apply underline around the intact rendered
				// cluster using its terminal profile instead.
				text := part.Underline(false).Render(cluster)
				rendered.WriteString(lipgloss.ColorProfile().String(text).Underline().String())
			} else {
				rendered.WriteString(part.Render(cluster))
			}
			remaining, state, index = rest, nextState, index+count
		}
		title = rendered.String()
	}
	// Keep terminal-native fallback rendering unchanged. Themed selections fill
	// the list width, including the space after short filenames.
	if style.GetBackground() != (lipgloss.NoColor{}) {
		style = style.Width(width - style.GetHorizontalBorderSize())
	}
	fmt.Fprint(w, style.Render(title))
}
