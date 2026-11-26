defmodule PhoenixKitSync.Web.CopyCodeJsTest do
  @moduledoc """
  The copy button of the connection code: its markup names the behaviour with
  `data-pks-copy` (no inline `onclick`, which a nonce Content-Security-Policy blocks) and
  the listener in `priv/static/assets/phoenix_kit_sync.js` does it.

  The listener itself is exercised by `test/js/copy_code.test.cjs` under node, which this
  file runs when node is installed.
  """
  use ExUnit.Case, async: true

  test "the copy button carries the code in data-pks-copy and no onclick" do
    source = File.read!("lib/phoenix_kit_sync/web/sender.ex")

    assert [button] = Regex.run(~r/<button\s+id="copy-code-btn".*?>/s, source)
    assert button =~ "data-pks-copy={@session.code}"
    refute button =~ "onclick"
    # The icons the listener swaps.
    assert source =~ ~s(class="w-5 h-5 copy-icon")
    assert source =~ ~s(class="w-5 h-5 text-success check-icon hidden")
  end

  test "the listener copies and swaps the icons (node)" do
    case System.find_executable("node") do
      nil ->
        IO.puts("[skip] node not found, test/js not run")

      node ->
        files = Path.wildcard("test/js/*.test.cjs")
        assert files != []
        {output, status} = System.cmd(node, ["--test" | files], stderr_to_stdout: true)
        assert status == 0, output
    end
  end
end
