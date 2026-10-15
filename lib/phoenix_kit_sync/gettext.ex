defmodule PhoenixKitSync.Gettext do
  @moduledoc "Gettext backend for phoenix_kit_sync."
  # One compiled module per locale and domain: the catalogues are large, and
  # split modules compile in parallel instead of one long serial compile that
  # blocks every app depending on this package. Lookups are unchanged.
  use Gettext.Backend,
    otp_app: :phoenix_kit_sync,
    split_module_by: [:locale, :domain]
end
