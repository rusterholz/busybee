# frozen_string_literal: true

require "busybee/credentials/tls"

RSpec.describe Busybee::Credentials::TLS do
  describe "#grpc_channel_credentials" do
    context "without custom certificate (system defaults)" do
      it "returns GRPC::Core::ChannelCredentials" do
        creds = described_class.new
        expect(creds.grpc_channel_credentials).to be_a(GRPC::Core::ChannelCredentials)
      end

      it "calls ChannelCredentials.new with no arguments to use system defaults" do
        creds = described_class.new

        # Verify that GRPC::Core::ChannelCredentials.new is called with zero arguments
        allow(GRPC::Core::ChannelCredentials).to receive(:new).with(no_args).and_call_original

        creds.grpc_channel_credentials

        expect(GRPC::Core::ChannelCredentials).to have_received(:new).with(no_args)
      end
    end

    context "with custom certificate" do
      let(:cert_contents) { "-----BEGIN CERTIFICATE-----\ntest\n-----END CERTIFICATE-----" }
      let(:cert_file) do
        Tempfile.new(["cert", ".pem"]).tap do |f|
          f.write(cert_contents)
          f.close
        end
      end

      after { cert_file.unlink }

      it "accepts certificate_file option" do
        creds = described_class.new(certificate_file: cert_file.path)
        expect(creds.certificate_file).to eq(cert_file.path)
      end

      it "returns GRPC::Core::ChannelCredentials using the custom certificate" do
        creds = described_class.new(certificate_file: cert_file.path)
        expect(creds.grpc_channel_credentials).to be_a(GRPC::Core::ChannelCredentials)
      end

      it "reads the certificate file and passes contents to ChannelCredentials" do
        creds = described_class.new(certificate_file: cert_file.path)

        # Verify File.read is called with the certificate path
        allow(File).to receive(:read).with(cert_file.path).and_return(cert_contents)

        # Verify ChannelCredentials.new is called with the certificate contents
        allow(GRPC::Core::ChannelCredentials).to receive(:new).with(cert_contents).and_call_original

        creds.grpc_channel_credentials

        expect(File).to have_received(:read).with(cert_file.path)
        expect(GRPC::Core::ChannelCredentials).to have_received(:new).with(cert_contents)
      end
    end
  end

  describe "#cluster_address" do
    it "accepts cluster_address parameter" do
      creds = described_class.new(cluster_address: "custom.zeebe.io:443")
      expect(creds.cluster_address).to eq("custom.zeebe.io:443")
    end

    it "falls back to Busybee.cluster_address when not provided" do
      original = Busybee.cluster_address
      Busybee.cluster_address = "default.zeebe.io:443"

      creds = described_class.new
      expect(creds.cluster_address).to eq("default.zeebe.io:443")
    ensure
      Busybee.cluster_address = original
    end
  end

  it "is a subclass of Credentials" do
    expect(described_class.superclass).to eq(Busybee::Credentials)
  end
end
