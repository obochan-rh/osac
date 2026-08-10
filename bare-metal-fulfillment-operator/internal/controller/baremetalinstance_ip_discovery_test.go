/*
Copyright 2026.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package controller

import (
	"context"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"

	"github.com/osac-project/osac/bare-metal-fulfillment-operator/api/v1alpha1"
	opv1alpha1 "github.com/osac-project/osac/osac-operator/api/v1alpha1"
	"github.com/osac-project/osac/osac-operator/pkg/provisioning"
)

var _ = Describe("BareMetalInstance IP Discovery", func() {
	var (
		ctx        context.Context
		reconciler *BareMetalInstanceReconciler
		bmi        *v1alpha1.BareMetalInstance
	)

	bmiForIPDiscovery := func(attachments []v1alpha1.BareMetalNetworkAttachment) *v1alpha1.BareMetalInstance {
		return &v1alpha1.BareMetalInstance{
			ObjectMeta: metav1.ObjectMeta{
				GenerateName: "test-bmi-ipd-",
				Namespace:    "default",
			},
			Spec: v1alpha1.BareMetalInstanceSpec{
				HostType:           "test-host",
				ExternalHostID:     "host-456",
				HostClass:          "openstack",
				TemplateID:         "noop",
				NetworkAttachments: attachments,
			},
		}
	}

	BeforeEach(func() {
		ctx = context.Background()
	})

	Describe("reconcileIPDiscovery", func() {
		Context("when no network attachments are configured", func() {
			BeforeEach(func() {
				bmi = bmiForIPDiscovery(nil)
				Expect(k8sClient.Create(ctx, bmi)).To(Succeed())
				reconciler = &BareMetalInstanceReconciler{
					Client:              k8sClient,
					Scheme:              k8sClient.Scheme(),
					IPDiscoveryProvider: &mockProvisioningProvider{},
				}
			})

			AfterEach(func() {
				Expect(k8sClient.Delete(ctx, bmi)).To(Succeed())
			})

			It("should skip with condition set to True/Skipped", func() {
				result, err := reconciler.reconcileIPDiscovery(ctx, bmi)
				Expect(err).NotTo(HaveOccurred())
				Expect(result.RequeueAfter).To(BeZero())

				cond := bmi.GetStatusCondition(v1alpha1.HostConditionIPDiscoveryComplete)
				Expect(cond).NotTo(BeNil())
				Expect(cond.Status).To(Equal(metav1.ConditionTrue))
				Expect(cond.Reason).To(Equal("Skipped"))
			})
		})

		Context("when IPDiscoveryProvider is nil", func() {
			BeforeEach(func() {
				bmi = bmiForIPDiscovery([]v1alpha1.BareMetalNetworkAttachment{
					{SubnetRef: "subnet-1", Interface: "data-0", Primary: true},
				})
				Expect(k8sClient.Create(ctx, bmi)).To(Succeed())
				reconciler = &BareMetalInstanceReconciler{
					Client:              k8sClient,
					Scheme:              k8sClient.Scheme(),
					IPDiscoveryProvider: nil,
				}
			})

			AfterEach(func() {
				Expect(k8sClient.Delete(ctx, bmi)).To(Succeed())
			})

			It("should skip with condition set to True/Skipped", func() {
				result, err := reconciler.reconcileIPDiscovery(ctx, bmi)
				Expect(err).NotTo(HaveOccurred())
				Expect(result.RequeueAfter).To(BeZero())

				cond := bmi.GetStatusCondition(v1alpha1.HostConditionIPDiscoveryComplete)
				Expect(cond).NotTo(BeNil())
				Expect(cond.Status).To(Equal(metav1.ConditionTrue))
				Expect(cond.Reason).To(Equal("Skipped"))
			})
		})

		Context("when IP discovery succeeds", func() {
			var mockProvider *mockProvisioningProvider

			BeforeEach(func() {
				bmi = bmiForIPDiscovery([]v1alpha1.BareMetalNetworkAttachment{
					{SubnetRef: "subnet-1", Interface: "data-0", Primary: true},
				})
				Expect(k8sClient.Create(ctx, bmi)).To(Succeed())

				mockProvider = &mockProvisioningProvider{}
				reconciler = &BareMetalInstanceReconciler{
					Client:                        k8sClient,
					Scheme:                        k8sClient.Scheme(),
					IPDiscoveryProvider:           mockProvider,
					AAPClient:                     nil, // no AAP client for unit tests
					ProvisionPollIntervalDuration: DefaultProvisionPollIntervalDuration,
				}
			})

			AfterEach(func() {
				Expect(k8sClient.Delete(ctx, bmi)).To(Succeed())
			})

			It("should set IPDiscoveryComplete to True and initialize statuses", func() {
				mockProvider.triggerProvisionFunc = func(_ context.Context, _ client.Object) (*provisioning.ProvisionResult, error) {
					return &provisioning.ProvisionResult{
						JobID:        "ipd-job-1",
						InitialState: opv1alpha1.JobStatePending,
					}, nil
				}
				mockProvider.getProvisionStatusFunc = func(_ context.Context, _ client.Object, _ string) (provisioning.ProvisionStatus, error) {
					return provisioning.ProvisionStatus{
						JobID: "ipd-job-1",
						State: opv1alpha1.JobStateSucceeded,
					}, nil
				}

				var foundCond *metav1.Condition
				for range 10 {
					_, _ = reconciler.reconcileIPDiscovery(ctx, bmi)
					foundCond = bmi.GetStatusCondition(v1alpha1.HostConditionIPDiscoveryComplete)
					if foundCond != nil && foundCond.Status == metav1.ConditionTrue {
						break
					}
					_ = k8sClient.Status().Update(ctx, bmi)
					Expect(k8sClient.Get(ctx, client.ObjectKeyFromObject(bmi), bmi)).To(Succeed())
				}

				Expect(foundCond).NotTo(BeNil())
				Expect(foundCond.Status).To(Equal(metav1.ConditionTrue))
				Expect(foundCond.Reason).To(Equal("Succeeded"))

				Expect(bmi.Status.NetworkAttachmentStatuses).To(HaveLen(1))
				Expect(bmi.Status.NetworkAttachmentStatuses[0].SubnetRef).To(Equal("subnet-1"))
				Expect(bmi.Status.NetworkAttachmentStatuses[0].Interface).To(Equal("data-0"))
				Expect(bmi.Status.NetworkAttachmentStatuses[0].Primary).To(BeTrue())
			})

			It("should track IP discovery jobs in status", func() {
				mockProvider.triggerProvisionFunc = func(_ context.Context, _ client.Object) (*provisioning.ProvisionResult, error) {
					return &provisioning.ProvisionResult{
						JobID:        "ipd-job-2",
						InitialState: opv1alpha1.JobStatePending,
					}, nil
				}
				mockProvider.getProvisionStatusFunc = func(_ context.Context, _ client.Object, _ string) (provisioning.ProvisionStatus, error) {
					return provisioning.ProvisionStatus{
						JobID: "ipd-job-2",
						State: opv1alpha1.JobStateSucceeded,
					}, nil
				}

				for range 10 {
					_, _ = reconciler.reconcileIPDiscovery(ctx, bmi)
					_ = k8sClient.Status().Update(ctx, bmi)
					Expect(k8sClient.Get(ctx, client.ObjectKeyFromObject(bmi), bmi)).To(Succeed())
				}

				Expect(bmi.Status.IPDiscoveryJobs).NotTo(BeEmpty())
				Expect(bmi.Status.IPDiscoveryJobs[0].JobID).To(Equal("ipd-job-2"))
			})
		})
	})
})
