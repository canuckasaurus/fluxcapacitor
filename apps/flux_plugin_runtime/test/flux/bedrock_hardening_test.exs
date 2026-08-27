defmodule Flux.Plugins.BedrockHardeningTest do
  use ExUnit.Case, async: true

  alias Flux.Plugins.Bedrock

  @good %{
    "access_key_id" => "AKIA_test",
    "secret_access_key" => "secret",
    "region" => "us-east-1"
  }

  test "a valid region shape passes the field check" do
    # Reaches the network step (which we don't stub) — the point is it
    # gets past require_fields rather than being rejected for the region.
    assert {:error, message} = Bedrock.validate_credentials(@good)
    refute message =~ "Region must look like"
  end

  test "an SSRF-shaped region is rejected before any request" do
    for evil <- [
          "0@169.254.169.254/",
          "us-east-1.evil.com",
          "us-east-1/",
          "../metadata",
          "internal:9000"
        ] do
      creds = Map.put(@good, "region", evil)
      assert {:error, "Region must look like us-east-1."} = Bedrock.validate_credentials(creds)
    end
  end
end
