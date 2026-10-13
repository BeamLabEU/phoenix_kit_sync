defmodule PhoenixKitSync.GettextCatalogueTest do
  use ExUnit.Case, async: true

  alias Expo.Message
  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKitSync.Errors
  alias PhoenixKitSync.Web.ConnectionsLive
  alias PhoenixKitSync.Web.History

  # The module ships its own catalogue. These tests read the compiled
  # backend, the way the UI does: every string the code asks for must come
  # back translated in each shipped language.

  @backend PhoenixKitSync.Gettext
  @locales ~w(et ru)

  defp pot_messages do
    "priv/gettext/default.pot"
    |> Expo.PO.parse_file!()
    |> Map.fetch!(:messages)
  end

  defp msgid(%{msgid: msgid}), do: IO.iodata_to_binary(msgid)

  # A value for every %{placeholder} of a string.
  defp bindings(msgid) do
    ~r/%\{(\w+)\}/
    |> Regex.scan(msgid, capture: :all_but_first)
    |> Map.new(fn [name] -> {String.to_atom(name), "x"} end)
  end

  test "ships Estonian and Russian" do
    assert Enum.sort(Gettext.known_locales(@backend)) == ["en", "et", "ru"]
  end

  for locale <- @locales do
    test "#{locale}: every string of the catalogue has a translation" do
      untranslated =
        for %Message.Singular{} = message <- pot_messages(),
            id = msgid(message),
            Gettext.with_locale(@backend, unquote(locale), fn ->
              Gettext.dgettext(@backend, "default", id, bindings(id))
            end) == Gettext.dgettext(@backend, "default", id, bindings(id)),
            # The same word in both languages.
            id not in ["PK"],
            do: id

      assert untranslated == []
    end

    test "#{locale}: every plural has every form, with the count in it" do
      for %Message.Plural{} = message <- pot_messages(), count <- [1, 2, 5, 11, 21, 101] do
        singular = msgid(message)
        plural = IO.iodata_to_binary(message.msgid_plural)

        text =
          Gettext.with_locale(@backend, unquote(locale), fn ->
            Gettext.dngettext(@backend, "default", singular, plural, count, %{})
          end)

        assert text =~ Integer.to_string(count), "#{singular} for #{count}: #{text}"
        refute text in [singular, plural]
        refute text =~ "%{"
      end
    end

    test "#{locale}: status labels come back translated" do
      connection_statuses =
        ~w(pending active suspended revoked expired loading offline not_found error)

      transfer_statuses =
        ~w(pending pending_approval approved denied in_progress completed failed cancelled expired)

      english = %{
        connection: Map.new(connection_statuses, &{&1, ConnectionsLive.status_label(&1)}),
        transfer: Map.new(transfer_statuses, &{&1, History.status_label(&1)})
      }

      Gettext.with_locale(@backend, unquote(locale), fn ->
        for status <- connection_statuses do
          label = ConnectionsLive.status_label(status)
          refute label in ["", status, english.connection[status]], status
        end

        for status <- transfer_statuses do
          label = History.status_label(status)
          refute label in ["", status, english.transfer[status]], status
        end

        assert Errors.message(:status_change_not_allowed) !=
                 "The remote site may not change this connection's status"
      end)
    end

    test "#{locale}: the sidebar and permission labels are in the catalogue" do
      Gettext.with_locale(@backend, unquote(locale), fn ->
        for tab <- PhoenixKitSync.admin_tabs() do
          assert tab.gettext_backend == @backend
          assert Tab.localized_label(tab) != tab.label, tab.label
        end

        metadata = PhoenixKitSync.permission_metadata()
        assert metadata.gettext_backend == @backend

        assert Gettext.dgettext(@backend, metadata.gettext_domain, metadata.label) !=
                 metadata.label
      end)
    end
  end

  test "English renders the source strings" do
    assert ConnectionsLive.status_label("suspended") == "Suspended"
    assert History.status_label("pending_approval") == "Pending Approval"
    assert History.status_label(nil) == ""
    assert ConnectionsLive.status_label("from_the_future") == "from_the_future"
  end

  test "no rendered string names the kit" do
    named = for message <- pot_messages(), id = msgid(message), id =~ ~r/phoenix ?kit/i, do: id
    assert named == []
  end
end
