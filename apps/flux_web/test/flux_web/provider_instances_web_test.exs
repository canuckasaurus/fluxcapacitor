defmodule FluxWeb.ProviderInstancesWebTest do
  use FluxWeb.ConnCase, async: false

  import Flux.AccountsFixtures
  import Phoenix.LiveViewTest

  alias Flux.Accounts
  alias Flux.Providers

  # Clonable fake provider with a full credential schema so the plugins
  # page can render its forms without any network.
  defmodule FakeRuntime do
    @compat %{
      id: "compat",
      name: "Compatible (fake)",
      version: "0.1.0",
      category: :model,
      description: "test provider",
      credential_schema: [
        %{
          key: "base_url",
          label: "Base URL",
          type: :url,
          required: true,
          placeholder: nil,
          help: nil
        },
        %{
          key: "api_key",
          label: "API key",
          type: :secret,
          required: false,
          placeholder: nil,
          help: nil
        }
      ]
    }

    def list_model_providers, do: [@compat]
    def list_datasource_plugins, do: []
    def list_tool_plugins, do: []
    def list_endpoint_plugins, do: []
    def validate_credentials(_plugin_id, _config), do: :ok
    def models(_plugin_id, _config), do: {:ok, [%{name: "compat-1", label: "Compat", type: :llm}]}
  end

  setup %{conn: conn} do
    previous = Application.get_env(:flux, :plugin_runtime)
    Application.put_env(:flux, :plugin_runtime, FakeRuntime)
    on_exit(fn -> Application.put_env(:flux, :plugin_runtime, previous) end)

    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Instances Web WS"})
    scope = Accounts.scope_for(account)

    %{conn: conn, scope: scope, workspace: workspace, account: account}
  end

  test "clone from the plugins page, rename, remove", %{conn: conn, account: account} do
    conn = log_in_account(conn, account)
    {:ok, lv, html} = live(conn, ~p"/console/plugins")
    assert html =~ "Clone"

    lv
    |> element("button[phx-click='start_clone'][phx-value-plugin-id='compat']")
    |> render_click()

    html =
      lv
      |> form("#clone-form-compat", %{
        "instance_name" => "Groq Prod",
        "credentials" => %{"base_url" => "https://groq.example.com/v1", "api_key" => "gsk-x"}
      })
      |> render_submit()

    assert html =~ "Groq Prod"
    assert html =~ "A named copy of compat with its own credentials"

    # The instance's own card renders with its credential row.
    assert has_element?(lv, "#plugin-compat--groq-prod")

    # Rename changes the label; the id (and the card) survives.
    lv
    |> element("button[phx-click='start_rename'][phx-value-plugin-id='compat@groq-prod']")
    |> render_click()

    html =
      lv
      |> form("#rename-form-compat--groq-prod", %{"label" => "Groq US East"})
      |> render_submit()

    assert html =~ "Groq US East"
    assert has_element?(lv, "#plugin-compat--groq-prod")

    # And it shows in the default-model picker under its label.
    assert html =~ "Groq US East — Compat"

    # Remove takes the card away.
    lv
    |> element("button[phx-click='delete_instance'][phx-value-plugin-id='compat@groq-prod']")
    |> render_click()

    refute has_element?(lv, "#plugin-compat--groq-prod")
  end

  describe "real runtime resolution" do
    test "instance ids resolve to the base module" do
      assert Flux.PluginRuntime.base_plugin_id("openai_compatible@groq") == "openai_compatible"
      assert {:ok, Flux.Plugins.Echo} = Flux.PluginRuntime.fetch_plugin("echo@anything")
      assert {:error, :unknown_plugin} = Flux.PluginRuntime.fetch_plugin("nope@x")
    end

    test "chat runs end-to-end through an instance id", %{scope: scope} do
      # Echo ignores credentials, so an echo instance exercises the whole
      # send→generate→finalize path under a synthetic provider id.
      Application.put_env(:flux, :plugin_runtime, Flux.PluginRuntime)

      {:ok, app} =
        Flux.Chat.create_app(scope, %{
          "name" => "Instance App",
          "provider_plugin_id" => "echo@cloned",
          "model" => "echo-1"
        })

      conversation = Flux.Chat.create_conversation(scope, app)
      {:ok, _user, assistant} = Flux.Chat.send_message(scope, app, conversation, "hello instance")

      done =
        Enum.reduce_while(1..50, nil, fn _try, _acc ->
          case Flux.Repo.get!(Flux.Chat.Message, assistant.id, skip_workspace_guard: true) do
            %{status: :streaming} -> Process.sleep(100) && {:cont, nil}
            done -> {:halt, done}
          end
        end)

      assert done.status == :completed
      assert done.content =~ "hello"
    end
  end

  test "instance models reach the app model picker", %{scope: scope} do
    {:ok, _id, _credential} =
      Providers.create_provider_instance(scope, "compat", "picker", %{"base_url" => "https://x"})

    models = Providers.available_models(scope)
    assert Enum.any?(models, &(&1.plugin_id == "compat@picker" and &1.plugin_name == "picker"))
  end
end
