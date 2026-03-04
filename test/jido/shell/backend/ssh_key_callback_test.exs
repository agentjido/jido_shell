defmodule Jido.Shell.Backend.SSHKeyCallbackTest do
  use Jido.Shell.Case, async: true

  alias Jido.Shell.Backend.SSH.KeyCallback

  test "accepts RSA keys for legacy and SHA2 RSA algorithms" do
    pem = rsa_private_key_pem()

    assert_rsa_key(KeyCallback.user_key(:"ssh-rsa", key: pem))
    assert_rsa_key(KeyCallback.user_key(:"rsa-sha2-256", key: pem))
    assert_rsa_key(KeyCallback.user_key(:"rsa-sha2-512", key: pem))
  end

  defp assert_rsa_key({:ok, key}) when is_tuple(key) do
    assert elem(key, 0) == :RSAPrivateKey
  end

  defp rsa_private_key_pem do
    key = :public_key.generate_key({:rsa, 1_024, 65_537})
    :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])
  end
end
