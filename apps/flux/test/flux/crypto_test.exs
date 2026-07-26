defmodule Flux.CryptoTest do
  use Flux.DataCase, async: false

  import Flux.AccountsFixtures

  alias Flux.Accounts
  alias Flux.Crypto
  alias Flux.Crypto.WorkspaceKey

  setup do
    account = account_fixture()
    {:ok, {workspace, _}} = Accounts.create_workspace(account, %{name: "Vault WS"})
    other = account_fixture()
    {:ok, {other_workspace, _}} = Accounts.create_workspace(other, %{name: "Other WS"})
    %{workspace: workspace, other_workspace: other_workspace}
  end

  test "encrypt/decrypt roundtrip", %{workspace: workspace} do
    assert {:ok, ciphertext} = Crypto.encrypt(workspace.id, "sk-super-secret")
    assert String.starts_with?(ciphertext, "v1:")
    refute ciphertext =~ "sk-super-secret"
    assert {:ok, "sk-super-secret"} = Crypto.decrypt(workspace.id, ciphertext)
  end

  test "first use creates exactly one DEK row", %{workspace: workspace} do
    {:ok, _} = Crypto.encrypt(workspace.id, "a")
    {:ok, _} = Crypto.encrypt(workspace.id, "b")

    assert [%WorkspaceKey{}] = Repo.all_by(WorkspaceKey, workspace_id: workspace.id)
  end

  test "ciphertext from one workspace does not decrypt in another", %{
    workspace: workspace,
    other_workspace: other_workspace
  } do
    {:ok, ciphertext} = Crypto.encrypt(workspace.id, "cross-tenant")
    assert {:error, :decryption_failed} = Crypto.decrypt(other_workspace.id, ciphertext)
  end

  test "malformed input is rejected", %{workspace: workspace} do
    assert {:error, :malformed_ciphertext} = Crypto.decrypt(workspace.id, "garbage")
    assert {:error, :malformed_ciphertext} = Crypto.decrypt(workspace.id, "v1:!!!")
  end

  test "DEK rows are encrypted at rest by the vault", %{workspace: workspace} do
    {:ok, _} = Crypto.encrypt(workspace.id, "x")

    # Read the raw column, bypassing the Cloak type.
    %{rows: [[raw_dek]]} =
      Repo.query!("SELECT dek FROM workspace_keys WHERE workspace_id = $1", [
        Ecto.UUID.dump!(workspace.id)
      ])

    decrypted_via_schema = Repo.get_by!(WorkspaceKey, workspace_id: workspace.id).dek
    assert byte_size(decrypted_via_schema) == 32
    assert raw_dek != decrypted_via_schema
  end

  test "rotate_dek re-encrypts and old cache is invalidated", %{workspace: workspace} do
    {:ok, c1} = Crypto.encrypt(workspace.id, "credential-one")
    {:ok, c2} = Crypto.encrypt(workspace.id, "credential-two")

    assert {:ok, reencrypted} = Crypto.rotate_dek(workspace.id, [{"a", c1}, {"b", c2}])
    assert length(reencrypted) == 2

    for {id, new_ciphertext} <- reencrypted do
      expected = if id == "a", do: "credential-one", else: "credential-two"
      assert {:ok, ^expected} = Crypto.decrypt(workspace.id, new_ciphertext)
      assert new_ciphertext != if(id == "a", do: c1, else: c2)
    end

    # Old ciphertexts no longer decrypt with the rotated DEK.
    assert {:error, :decryption_failed} = Crypto.decrypt(workspace.id, c1)
  end
end
