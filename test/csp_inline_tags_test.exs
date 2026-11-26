defmodule PhoenixKitSync.CSPInlineTagsTest do
  @moduledoc """
  The pages of this module work under a host Content-Security-Policy that allows inline code
  by nonce only (`script-src 'self' 'nonce-…'`): an inline `<style>` / `<script>` must carry
  the page's nonce, and there is no inline event handler at all (no nonce can cover an
  attribute; a `phx-` binding or a `data-pks-*` attribute handled by the listener in
  `phoenix_kit_sync.js` does that work).

  The module renders no inline tag today. This test keeps it that way.

  Modelled on core's `test/phoenix_kit_web/csp_inline_tags_test.exs`.
  """
  use ExUnit.Case, async: true

  @doc_heredoc ~r/@(?:moduledoc|doc|typedoc|shortdoc)\s+(?:~[sS])?"""\n.*?\n\s*"""/s

  @bundles ["priv/static/assets/phoenix_kit_sync.js"]

  @tag_opening ~r/<(script|style)\b[^>]*>/s

  # Exempt: a colocated hook (`<script :type={Phoenix.LiveView.ColocatedHook}>`) is taken out
  # of the template by the compiler and is never rendered as an inline tag.
  test "no inline <script> or <style> in lib/ is written without a nonce" do
    offenders =
      for path <- Path.wildcard("lib/**/*.{ex,heex}"),
          {opening, number} <- tag_openings(path),
          not String.contains?(opening, "src="),
          not String.contains?(opening, "ColocatedHook"),
          not (opening =~ "CSP.nonce("),
          do: "#{path}:#{number}"

    assert offenders == [],
           "inline tags without a nonce (feature-detect `PhoenixKitWeb.CSP.nonce/1`, " <>
             "see AGENTS.md, \"Content-Security-Policy\"):\n" <> Enum.join(offenders, "\n")
  end

  # `onclick="…"`, `onclick='…'`, `onclick={…}`, and the same with spaces around `=` for the
  # events a browser knows (a bare `on\w+ =` would also match Elixir like `only = "x"`).
  @events ~w(click dblclick change input submit reset invalid select focus blur focusin focusout
             keydown keyup keypress load error scroll wheel resize toggle contextmenu copy cut
             paste drop) ++
            ~w(mousedown mouseup mouseover mouseout mousemove mouseenter mouseleave) ++
            ~w(touchstart touchend touchmove pointerdown pointerup pointermove) ++
            ~w(dragstart dragend dragover dragenter dragleave animationend transitionend)
  @handler Regex.compile!(
             "\\son(?!ly=)[a-z]+=[\"'{]|\\son(?:#{Enum.join(@events, "|")})\\s*=\\s*[\"'{]"
           )
  @js_url ~r/\b(?:href|src|action|formaction)\s*=\s*["'{]\s*["']?\s*javascript:/i

  test "no markup in lib/ carries an inline event handler" do
    offenders =
      for path <- Path.wildcard("lib/**/*.{ex,heex}"),
          {line, number} <- path |> File.read!() |> code_lines(),
          not (line =~ ~r/^\s*(#|iex>|\.\.\.>)/),
          line =~ @handler or line =~ @js_url,
          do: "#{path}:#{number}"

    assert offenders == [],
           "inline handlers (no nonce covers them; use a `phx-` binding or a `data-pks-*` " <>
             "attribute handled in phoenix_kit_sync.js):\n" <> Enum.join(offenders, "\n")
  end

  test "the handler pattern matches what it is meant to" do
    assert ~s[<ul onclick="x()">] =~ @handler
    assert ~s(<div onclick={@x}>) =~ @handler
    assert ~s(<img onerror = 'x'>) =~ @handler
    assert ~s[<a href="javascript:void(0)">] =~ @js_url
    refute ~s(<button phx-click="go">) =~ @handler
    refute ~s(<.table only={@only}>) =~ @handler
    refute ~s(only = "x") =~ @handler
  end

  test "the bundle builds no markup with an inline event handler" do
    offenders =
      for {path, line, number} <- bundle_lines(),
          line =~ ~r/\son[a-z]+=\\?["']/ or line =~ ~r/javascript:/i,
          do: "#{path}:#{number}"

    assert offenders == [], Enum.join(offenders, "\n")
  end

  # A `<style>` / `<script>` the bundle creates is checked against the page's policy like any
  # other: it is stamped with the page's nonce (core's `PhoenixKitInternals.adoptStyle`, when
  # there) before it is inserted, and never written as a string for `innerHTML`. No `eval`
  # either: `script-src` without 'unsafe-eval' blocks it.
  test "the bundle creates no unstamped <style>/<script>, and evaluates no strings" do
    lines = bundle_lines()

    offenders =
      for {{path, line, number}, index} <- Enum.with_index(lines),
          next = lines |> Enum.slice(index + 1, 6) |> Enum.map(&elem(&1, 1)),
          problem = bundle_problem(line, next),
          do: "#{path}:#{number} #{problem}"

    assert offenders == [], Enum.join(offenders, "\n")
  end

  defp bundle_problem(line, next_lines) do
    cond do
      line =~ ~r/createElement\(["'](?:style|script)["']\)/ and
          not Enum.any?(next_lines, &(&1 =~ "adoptStyle")) ->
        "creates a <style>/<script> that is not stamped in the next lines"

      line =~ ~r/["'`]<(?:style|script)\b/ ->
        "builds a <style>/<script> tag as a string"

      line =~ ~r/\beval\(|new Function\(/ ->
        "evaluates a string"

      true ->
        nil
    end
  end

  # The attributes that replaced the inline handlers are only as good as the listener behind
  # them: each one the markup uses is handled in the bundle, and the other way round.
  test "every data-pks-* attribute in the markup has its listener in the bundle" do
    used =
      for path <- Path.wildcard("lib/**/*.{ex,heex}"),
          [name] <- Regex.scan(~r/data-pks-[a-z-]+/, path |> File.read!() |> markup_source()),
          uniq: true,
          do: name

    handled =
      for {_path, line, _number} <- bundle_lines(),
          [name] <- Regex.scan(~r/data-pks-[a-z-]+/, line),
          uniq: true,
          do: name

    assert Enum.sort(used) == ["data-pks-copy"]
    assert Enum.sort(handled) == Enum.sort(used)
  end

  # Core's `data-pk-*` listeners exist only in cores newer than this module's core floor: a
  # behaviour hung on one would be dead on the published core.
  test "the markup hangs no behaviour on core's data-pk-* listeners" do
    offenders =
      for path <- Path.wildcard("lib/**/*.{ex,heex}"),
          {line, number} <- path |> File.read!() |> code_lines(),
          line =~ ~r/\sdata-pk-(?:blur|copy|copy-from|img-error|no-submit|no-enter|zero-clear)\b/,
          do: "#{path}:#{number}"

    assert offenders == [], Enum.join(offenders, "\n")
  end

  test "the bundle is declared by js_sources/0 and ships in the package" do
    assert [%{app: :phoenix_kit_sync, file: file, global: "PhoenixKitSyncHooks"}] =
             PhoenixKitSync.js_sources()

    assert Path.join("priv", file) in @bundles
    assert File.read!(Path.join("priv", file)) =~ "window.PhoenixKitSyncHooks"
    assert "priv" in Mix.Project.config()[:package][:files]
  end

  test "the scanned bundle is the only JavaScript the module ships" do
    assert Enum.sort(Path.wildcard("{lib,priv}/**/*.{js,ts}")) == Enum.sort(@bundles)
  end

  # The bundles' lines without their comment lines.
  defp bundle_lines do
    for path <- @bundles,
        {line, number} <- path |> File.read!() |> String.split("\n") |> Enum.with_index(1),
        not (line =~ ~r{^\s*(//|\*|/\*)}),
        do: {path, line, number}
  end

  # Every opening `<script …>` / `<style …>` of the file with the line it starts on.
  defp tag_openings(path) do
    source = path |> File.read!() |> markup_source()

    for [{start, length}] <- Regex.scan(@tag_opening, source, return: :index, capture: :first) do
      line = source |> binary_part(0, start) |> String.split("\n") |> length()
      {binary_part(source, start, length), line}
    end
  end

  # The source with what is not markup blanked, line numbers kept: documentation, HEEx
  # comments and Elixir comment lines (a tag there is prose).
  defp markup_source(source) do
    blank = fn text -> String.replace(text, ~r/[^\n]/, "") end

    source
    |> then(&Regex.replace(@doc_heredoc, &1, blank))
    |> then(&Regex.replace(~r/<%!--.*?--%>/s, &1, blank))
    |> then(&Regex.replace(~r/^[ \t]*#[^\n]*$/m, &1, ""))
  end

  defp code_lines(source) do
    @doc_heredoc
    |> Regex.replace(source, fn doc -> String.replace(doc, ~r/[^\n]/, "") end)
    |> String.split("\n")
    |> Enum.with_index(1)
  end
end
