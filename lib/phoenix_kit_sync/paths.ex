defmodule PhoenixKitSync.Paths do
  @moduledoc """
  Centralized URL helpers for PhoenixKitSync admin pages.

  All paths go through `PhoenixKit.Utils.Routes.path/1` to respect
  the configurable URL prefix.
  """

  alias PhoenixKit.Utils.Routes

  @base "/admin/sync"

  def index, do: Routes.path(@base)
  def connections, do: Routes.path("#{@base}/connections")
  def history, do: Routes.path("#{@base}/history")
end
