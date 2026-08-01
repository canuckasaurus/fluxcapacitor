defmodule Flux.Plugins.RSSTest do
  use ExUnit.Case, async: false

  alias Flux.Plugin.Datasource.SourceDoc
  alias Flux.Plugins.RSS

  @credentials %{"feed_url" => "https://feeds.example.com/blog.xml"}

  @feed """
  <?xml version="1.0"?>
  <rss version="2.0"><channel>
    <title>Blog</title>
    <item>
      <title><![CDATA[Post one]]></title>
      <link>https://blog.example.com/one</link>
      <guid>post-1</guid>
      <description><![CDATA[<p>Body of post &amp; one.</p>]]></description>
    </item>
    <item>
      <title>Post two</title>
      <link>https://blog.example.com/two</link>
      <guid>post-2</guid>
      <description></description>
    </item>
  </channel></rss>
  """

  @page """
  <html><head><style>body { color: red }</style></head>
  <body><h1>Post two</h1><p>Fetched from the linked page.</p></body></html>
  """

  setup do
    Application.put_env(:flux_plugin_runtime, :req_options, plug: {Req.Test, Flux.RSSStub})
    on_exit(fn -> Application.delete_env(:flux_plugin_runtime, :req_options) end)

    Req.Test.stub(Flux.RSSStub, fn conn ->
      case conn.host do
        "feeds.example.com" -> Plug.Conn.send_resp(conn, 200, @feed)
        "blog.example.com" -> Plug.Conn.send_resp(conn, 200, @page)
      end
    end)

    :ok
  end

  test "list_documents parses items with guid ids and CDATA titles" do
    assert {:ok, docs} = RSS.list_documents(@credentials)

    assert docs == [
             %SourceDoc{id: "post-1", name: "Post one"},
             %SourceDoc{id: "post-2", name: "Post two"}
           ]
  end

  test "fetch_document uses the item body when present, stripped to text" do
    assert {:ok, %{name: "Post one", content: content}} =
             RSS.fetch_document(@credentials, "post-1")

    assert content == "Body of post & one."
  end

  test "fetch_document falls back to fetching the linked page" do
    assert {:ok, %{name: "Post two", content: content}} =
             RSS.fetch_document(@credentials, "post-2")

    assert content =~ "Fetched from the linked page."
    refute content =~ "color: red"
    refute content =~ "<p>"
  end

  test "fetch_document refuses ids the feed does not advertise" do
    assert {:error, "item is not in the feed"} =
             RSS.fetch_document(@credentials, "https://evil.example.com/steal")
  end

  test "non-feed bodies and missing credentials error clearly" do
    Req.Test.stub(Flux.RSSStub, fn conn ->
      Plug.Conn.send_resp(conn, 200, "<html><body>not a feed</body></html>")
    end)

    assert {:error, message} = RSS.list_documents(@credentials)
    assert message =~ "RSS/Atom"

    assert {:error, "feed_url is required"} = RSS.list_documents(%{})
  end

  test "atom feeds parse entries with href links and summaries" do
    atom = """
    <feed xmlns="http://www.w3.org/2005/Atom">
      <entry>
        <title>Atom post</title>
        <id>urn:uuid:1</id>
        <link href="https://blog.example.com/atom-post"/>
        <summary>Short summary text.</summary>
      </entry>
    </feed>
    """

    Req.Test.stub(Flux.RSSStub, fn conn -> Plug.Conn.send_resp(conn, 200, atom) end)

    assert {:ok, [%SourceDoc{id: "urn:uuid:1", name: "Atom post"}]} =
             RSS.list_documents(@credentials)

    assert {:ok, %{content: "Short summary text."}} =
             RSS.fetch_document(@credentials, "urn:uuid:1")
  end

  test "the runtime exposes rss as a datasource plugin and proxies calls" do
    assert Enum.any?(Flux.PluginRuntime.list_datasource_plugins(), &(&1.id == "rss"))

    assert {:ok, [%SourceDoc{id: "post-1"} | _rest]} =
             Flux.PluginRuntime.datasource_documents("rss", @credentials)

    assert {:ok, %{name: "Post one"}} =
             Flux.PluginRuntime.fetch_datasource_document("rss", @credentials, "post-1")

    assert {:error, :unknown_plugin} =
             Flux.PluginRuntime.datasource_documents("nope", @credentials)
  end
end
