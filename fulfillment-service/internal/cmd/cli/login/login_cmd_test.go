/*
Copyright (c) 2025 Red Hat Inc.

Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
License. You may obtain a copy of the License at

  http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an
"AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific
language governing permissions and limitations under the License.
*/

package login

import (
	"context"
	"os"
	"path/filepath"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/spf13/pflag"

	"github.com/osac-project/osac/fulfillment-service/internal/oauth"
)

var _ = Describe("readTrimmedFile", func() {
	var runner *runnerContext
	var tmpDir string

	BeforeEach(func() {
		runner = &runnerContext{}
		var err error
		tmpDir, err = os.MkdirTemp("", "login-test-*")
		Expect(err).NotTo(HaveOccurred())
	})

	AfterEach(func() {
		os.RemoveAll(tmpDir)
	})

	It("reads a file and trims a trailing newline", func() {
		f := filepath.Join(tmpDir, "secret.txt")
		Expect(os.WriteFile(f, []byte("mysecret\n"), 0600)).To(Succeed())
		result, err := runner.readTrimmedFile(f)
		Expect(err).NotTo(HaveOccurred())
		Expect(result).To(Equal("mysecret"))
	})

	It("reads a file and trims surrounding whitespace", func() {
		f := filepath.Join(tmpDir, "secret.txt")
		Expect(os.WriteFile(f, []byte("  mysecret  \n"), 0600)).To(Succeed())
		result, err := runner.readTrimmedFile(f)
		Expect(err).NotTo(HaveOccurred())
		Expect(result).To(Equal("mysecret"))
	})

	It("reads an empty file and returns an empty string", func() {
		f := filepath.Join(tmpDir, "empty.txt")
		Expect(os.WriteFile(f, []byte(""), 0600)).To(Succeed())
		result, err := runner.readTrimmedFile(f)
		Expect(err).NotTo(HaveOccurred())
		Expect(result).To(Equal(""))
	})

	It("returns an error when the file does not exist", func() {
		_, err := runner.readTrimmedFile(filepath.Join(tmpDir, "nonexistent.txt"))
		Expect(err).To(HaveOccurred())
	})
})

// newFileFlagSet creates a minimal pflag.FlagSet that covers all flags read by
// resolveFileFlags and inferFlow, bound to the given runnerContext.
func newFileFlagSet(r *runnerContext) *pflag.FlagSet {
	fs := pflag.NewFlagSet("test", pflag.ContinueOnError)
	fs.StringVar(&r.args.password, "password", "", "")
	fs.StringVar(&r.args.passwordFile, "password-file", "", "")
	fs.StringVar(&r.args.clientSecret, "client-secret", "", "")
	fs.StringVar(&r.args.clientSecretFile, "client-secret-file", "", "")
	fs.StringVar(&r.args.user, "user", "", "")
	fs.StringVar(&r.args.userFile, "user-file", "", "")
	fs.StringVar(&r.args.clientId, "client-id", "", "")
	fs.StringVar(&r.args.clientIdFile, "client-id-file", "", "")
	// inferFlow also checks these:
	fs.StringVar(&r.args.flow, "flow", defaultFlow, "")
	fs.StringVar(&r.args.flow, "oauth-flow", defaultFlow, "")
	var dummy string
	fs.StringVar(&dummy, "oauth-client-secret", "", "")
	fs.StringVar(&dummy, "oauth-user", "", "")
	fs.StringVar(&dummy, "oauth-password", "", "")
	return fs
}

var _ = Describe("resolveFileFlags", func() {
	var runner *runnerContext
	var tmpDir string

	BeforeEach(func() {
		runner = &runnerContext{}
		runner.flags = newFileFlagSet(runner)
		var err error
		tmpDir, err = os.MkdirTemp("", "login-test-*")
		Expect(err).NotTo(HaveOccurred())
	})

	AfterEach(func() {
		os.RemoveAll(tmpDir)
	})

	writeFile := func(name, content string) string {
		path := filepath.Join(tmpDir, name)
		ExpectWithOffset(1, os.WriteFile(path, []byte(content), 0600)).To(Succeed())
		return path
	}

	Describe("--password-file", func() {
		It("reads password from file and trims whitespace", func() {
			path := writeFile("pw.txt", "mypassword\n")
			Expect(runner.flags.Parse([]string{"--password-file=" + path})).To(Succeed())
			Expect(runner.resolveFileFlags()).To(Succeed())
			Expect(runner.args.password).To(Equal("mypassword"))
		})

		It("returns an error when both --password and --password-file are provided", func() {
			path := writeFile("pw.txt", "mypassword\n")
			Expect(runner.flags.Parse([]string{"--password=direct", "--password-file=" + path})).To(Succeed())
			Expect(runner.resolveFileFlags()).To(MatchError(ContainSubstring("mutually exclusive")))
		})

		It("returns an error when the file does not exist", func() {
			Expect(runner.flags.Parse([]string{"--password-file=" + filepath.Join(tmpDir, "missing.txt")})).To(Succeed())
			Expect(runner.resolveFileFlags()).To(HaveOccurred())
		})
	})

	Describe("--client-secret-file", func() {
		It("reads client secret from file and trims whitespace", func() {
			path := writeFile("secret.txt", "tok123\n")
			Expect(runner.flags.Parse([]string{"--client-secret-file=" + path})).To(Succeed())
			Expect(runner.resolveFileFlags()).To(Succeed())
			Expect(runner.args.clientSecret).To(Equal("tok123"))
		})

		It("returns an error when both --client-secret and --client-secret-file are provided", func() {
			path := writeFile("secret.txt", "tok123\n")
			Expect(runner.flags.Parse([]string{"--client-secret=direct", "--client-secret-file=" + path})).To(Succeed())
			Expect(runner.resolveFileFlags()).To(MatchError(ContainSubstring("mutually exclusive")))
		})
	})

	Describe("--user-file", func() {
		It("reads user from file and trims whitespace", func() {
			path := writeFile("user.txt", "alice\n")
			Expect(runner.flags.Parse([]string{"--user-file=" + path})).To(Succeed())
			Expect(runner.resolveFileFlags()).To(Succeed())
			Expect(runner.args.user).To(Equal("alice"))
		})

		It("returns an error when both --user and --user-file are provided", func() {
			path := writeFile("user.txt", "alice\n")
			Expect(runner.flags.Parse([]string{"--user=bob", "--user-file=" + path})).To(Succeed())
			Expect(runner.resolveFileFlags()).To(MatchError(ContainSubstring("mutually exclusive")))
		})
	})

	Describe("--client-id-file", func() {
		It("reads client ID from file and trims whitespace", func() {
			path := writeFile("id.txt", "my-client\n")
			Expect(runner.flags.Parse([]string{"--client-id-file=" + path})).To(Succeed())
			Expect(runner.resolveFileFlags()).To(Succeed())
			Expect(runner.args.clientId).To(Equal("my-client"))
		})

		It("returns an error when both --client-id and --client-id-file are provided", func() {
			path := writeFile("id.txt", "my-client\n")
			Expect(runner.flags.Parse([]string{"--client-id=other", "--client-id-file=" + path})).To(Succeed())
			Expect(runner.resolveFileFlags()).To(MatchError(ContainSubstring("mutually exclusive")))
		})
	})
})

var _ = Describe("inferFlow", func() {
	var runner *runnerContext

	BeforeEach(func() {
		runner = &runnerContext{}
		runner.args.flow = defaultFlow
		runner.flags = newFileFlagSet(runner)
	})

	It("sets credentials flow when --client-secret-file is provided", func() {
		Expect(runner.flags.Parse([]string{"--client-secret-file=foo"})).To(Succeed())
		Expect(runner.inferFlow(context.Background())).To(Succeed())
		Expect(runner.args.flow).To(Equal(string(oauth.CredentialsFlow)))
	})

	It("sets credentials flow when --client-id-file is provided", func() {
		Expect(runner.flags.Parse([]string{"--client-id-file=foo"})).To(Succeed())
		Expect(runner.inferFlow(context.Background())).To(Succeed())
		Expect(runner.args.flow).To(Equal(string(oauth.CredentialsFlow)))
	})

	It("sets password flow when --user-file is provided", func() {
		Expect(runner.flags.Parse([]string{"--user-file=foo"})).To(Succeed())
		Expect(runner.inferFlow(context.Background())).To(Succeed())
		Expect(runner.args.flow).To(Equal(string(oauth.PasswordFlow)))
	})

	It("sets password flow when --password-file is provided", func() {
		Expect(runner.flags.Parse([]string{"--password-file=foo"})).To(Succeed())
		Expect(runner.inferFlow(context.Background())).To(Succeed())
		Expect(runner.args.flow).To(Equal(string(oauth.PasswordFlow)))
	})

	It("existing --client-secret still triggers credentials flow (backwards compat)", func() {
		Expect(runner.flags.Parse([]string{"--client-secret=foo"})).To(Succeed())
		Expect(runner.inferFlow(context.Background())).To(Succeed())
		Expect(runner.args.flow).To(Equal(string(oauth.CredentialsFlow)))
	})

	It("existing --password still triggers password flow (backwards compat)", func() {
		Expect(runner.flags.Parse([]string{"--password=foo"})).To(Succeed())
		Expect(runner.inferFlow(context.Background())).To(Succeed())
		Expect(runner.args.flow).To(Equal(string(oauth.PasswordFlow)))
	})

	It("does not change flow when --flow is explicitly set", func() {
		Expect(runner.flags.Parse([]string{"--flow=code", "--client-secret-file=foo"})).To(Succeed())
		Expect(runner.inferFlow(context.Background())).To(Succeed())
		Expect(runner.args.flow).To(Equal("code"))
	})
})
