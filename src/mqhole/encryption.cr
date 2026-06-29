require "aes_gcm"
require "base64"
require "json"
require "openssl"
require "random/secure"

module Mqhole
  module Encryption
    ALGORITHM              = "aes-256-gcm"
    KDF                    = "pbkdf2-hmac-sha256"
    DEFAULT_KDF_ITERATIONS = 210_000
    KEY_SIZE               =      32
    SALT_SIZE              =      16
    NONCE_PREFIX_SIZE      =       8
    NONCE_SIZE             =      12
    TAG_SIZE               =      16

    class Error < Exception
    end

    struct Metadata
      include JSON::Serializable

      getter version : Int32
      getter algorithm : String
      getter kdf : String
      getter salt : String
      getter iterations : Int32
      getter nonce_prefix : String

      def initialize(
        @version : Int32,
        @algorithm : String,
        @kdf : String,
        @salt : String,
        @iterations : Int32,
        @nonce_prefix : String,
      )
      end

      def self.generate(iterations : Int32 = DEFAULT_KDF_ITERATIONS) : self
        new(
          version: 1,
          algorithm: ALGORITHM,
          kdf: KDF,
          salt: Base64.strict_encode(Random::Secure.random_bytes(SALT_SIZE)),
          iterations: iterations,
          nonce_prefix: Base64.strict_encode(Random::Secure.random_bytes(NONCE_PREFIX_SIZE))
        )
      end

      def salt_bytes : Bytes
        Base64.decode(salt)
      end

      def nonce_prefix_bytes : Bytes
        Base64.decode(nonce_prefix)
      end
    end

    class Context
      getter metadata : Metadata

      @key : Bytes

      def self.generate(passphrase : String) : self
        new(passphrase, Metadata.generate)
      end

      def self.from_metadata(passphrase : String, metadata : Metadata) : self
        new(passphrase, metadata)
      end

      def initialize(passphrase : String, @metadata : Metadata)
        validate_metadata
        @key = self.class.derive_key(passphrase, metadata)
      end

      def encrypt_chunk(chunk : Bytes, manifest, index : Int32) : Bytes
        encrypted = cipher.encrypt(
          key: @key,
          plaintext: chunk,
          iv: nonce(index),
          aad: aad(manifest, index)
        )

        IO::Memory.new.tap do |io|
          io.write(encrypted.ciphertext)
          io.write(encrypted.auth_tag)
        end.to_slice
      end

      def decrypt_chunk(payload : Bytes, manifest, index : Int32) : Bytes
        raise Error.new("could not decrypt transfer; check the passphrase") if payload.size < TAG_SIZE

        ciphertext = payload[0, payload.size - TAG_SIZE]
        tag = payload[payload.size - TAG_SIZE, TAG_SIZE]
        cipher.decrypt(
          key: @key,
          ciphertext: ciphertext,
          iv: nonce(index),
          auth_tag: tag,
          aad: aad(manifest, index)
        )
      rescue OpenSSL::Cipher::Error
        raise Error.new("could not decrypt transfer; check the passphrase")
      end

      def self.derive_key(passphrase : String, metadata : Metadata) : Bytes
        key = Bytes.new(KEY_SIZE)
        passphrase_bytes = passphrase.to_slice
        status = LibCrypto.pkcs5_pbkdf2_hmac(
          passphrase_bytes.to_unsafe.as(LibC::Char*),
          passphrase_bytes.size,
          metadata.salt_bytes,
          metadata.salt_bytes.size,
          metadata.iterations,
          LibCrypto.evp_sha256,
          key.size,
          key
        )
        raise Error.new("could not derive encryption key") unless status == 1

        key
      end

      private def validate_metadata : Nil
        unless metadata.version == 1 && metadata.algorithm == ALGORITHM && metadata.kdf == KDF
          raise Error.new("unsupported encryption metadata")
        end
        raise Error.new("invalid encryption salt") unless metadata.salt_bytes.size == SALT_SIZE
        unless metadata.nonce_prefix_bytes.size == NONCE_PREFIX_SIZE
          raise Error.new("invalid encryption nonce")
        end
        raise Error.new("invalid encryption iterations") unless metadata.iterations.positive?
      end

      private def nonce(index : Int32) : Bytes
        raise Error.new("too many encrypted chunks") if index < 0

        nonce = Bytes.new(NONCE_SIZE)
        prefix = metadata.nonce_prefix_bytes
        nonce[0, prefix.size].copy_from(prefix)
        nonce[8] = ((index >> 24) & 0xff).to_u8
        nonce[9] = ((index >> 16) & 0xff).to_u8
        nonce[10] = ((index >> 8) & 0xff).to_u8
        nonce[11] = (index & 0xff).to_u8
        nonce
      end

      private def aad(manifest, index : Int32) : Bytes
        JSON.build do |json|
          json.object do
            json.field "id", manifest.id
            json.field "version", manifest.version
            json.field "source_name", manifest.source_name
            json.field "size", manifest.size
            json.field "chunk_size", manifest.chunk_size
            json.field "chunk_index", index
          end
        end.to_slice
      end

      private def cipher : AesGcm::Cipher
        AesGcm::Cipher.new(iv_size: NONCE_SIZE, tag_size: TAG_SIZE, key_size: KEY_SIZE)
      end
    end

    def self.generate_passphrase : String
      Random::Secure.urlsafe_base64(24, padding: false)
    end
  end
end
