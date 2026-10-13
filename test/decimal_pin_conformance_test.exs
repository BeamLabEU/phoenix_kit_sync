defmodule PhoenixKitSync.DecimalPinConformanceTest do
  use ExUnit.Case, async: true

  test "the published requirement refuses affected versions and admits patched 3.x releases" do
    {:decimal, requirement} = Enum.find(Mix.Project.config()[:deps], &(elem(&1, 0) == :decimal))

    for version <- ~w(2.4.1 3.0.0 3.1.0 3.1.1),
        do: refute(Version.match?(version, requirement))

    for version <- ~w(3.1.2 3.2.0 3.99.0),
        do: assert(Version.match?(version, requirement))

    refute Version.match?("4.0.0", requirement)
  end
end
