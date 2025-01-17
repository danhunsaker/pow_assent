defmodule PowAssent.HTTPAdapter.MintTest do
  use ExUnit.Case
  doctest PowAssent.HTTPAdapter.Mint

  alias PowAssent.HTTPAdapter.{Mint, HTTPResponse}

  @expired_certificate_url "https://expired.badssl.com"
  @hsts_certificate_url "https://hsts.badssl.com"
  @unreachable_http_url "http://localhost:8888/"

  {otp_version, _} = Integer.parse(to_string(:erlang.system_info(:otp_release)))
  @certificate_expired_error if otp_version >= 22, do: {:tls_alert, {:certificate_expired, 'received CLIENT ALERT: Fatal - Certificate Expired'}}, else: {:tls_alert, 'certificate expired'}

  describe "request/4" do
    test "handles SSL" do
      assert {:ok, %HTTPResponse{status: 200}} = Mint.request(:get, @hsts_certificate_url, nil, [])
      assert {:error, @certificate_expired_error} = Mint.request(:get, @expired_certificate_url, nil, [])

      assert {:ok, %HTTPResponse{status: 200}} = Mint.request(:get, @expired_certificate_url, nil, [], transport_opts: [verify: :verify_none])

      assert {:error, :econnrefused} = Mint.request(:get, @unreachable_http_url, nil, [])
    end
  end
end
