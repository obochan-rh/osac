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
	"fmt"

	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	logf "sigs.k8s.io/controller-runtime/pkg/log"

	"github.com/osac-project/osac/bare-metal-fulfillment-operator/api/v1alpha1"
	"github.com/osac-project/osac/bare-metal-fulfillment-operator/internal/shared"
	opv1alpha1 "github.com/osac-project/osac/osac-operator/api/v1alpha1"
)

const (
	autoCreatedLabel    = shared.OsacPrefix + "/auto-created"
	autoCreatedForLabel = shared.OsacPrefix + "/auto-created-for"
)

// reconcileAutoCleanup deletes auto-provisioned ExternalIPAttachment and ExternalIP
// resources when a BareMetalInstance is deleted. Manually created resources are left
// for the tenant. Deletion order: ExternalIPAttachment first, then ExternalIP.
func (r *BareMetalInstanceReconciler) reconcileAutoCleanup(
	ctx context.Context,
	bareMetalInstance *v1alpha1.BareMetalInstance,
) (ctrl.Result, bool, error) {
	log := logf.FromContext(ctx)

	if !controllerutil.ContainsFinalizer(bareMetalInstance, BareMetalInstanceCleanupFinalizer) {
		return ctrl.Result{}, true, nil
	}

	log.Info("Running auto-cleanup for auto-provisioned resources")

	bmiUID := string(bareMetalInstance.UID)

	// Phase 1: Delete auto-provisioned ExternalIPAttachments
	attachmentList := &opv1alpha1.ExternalIPAttachmentList{}
	if err := r.List(ctx, attachmentList,
		client.InNamespace(bareMetalInstance.Namespace),
		client.MatchingLabels{
			autoCreatedLabel:    "true",
			autoCreatedForLabel: bmiUID,
		},
	); err != nil {
		return ctrl.Result{}, false,
			fmt.Errorf("failed to list ExternalIPAttachments: %w", err)
	}

	for i := range attachmentList.Items {
		att := &attachmentList.Items[i]
		if att.DeletionTimestamp.IsZero() {
			log.Info("Deleting auto-provisioned ExternalIPAttachment",
				"name", att.Name)
			if err := r.Delete(ctx, att); client.IgnoreNotFound(err) != nil {
				return ctrl.Result{}, false,
					fmt.Errorf("failed to delete ExternalIPAttachment %s: %w",
						att.Name, err)
			}
		}
	}

	if len(attachmentList.Items) > 0 {
		log.Info("Waiting for ExternalIPAttachment deletion to complete",
			"remaining", len(attachmentList.Items))
		return ctrl.Result{
			RequeueAfter: DefaultManagementRecheckIntervalDuration,
		}, false, nil
	}

	// Phase 2: Delete auto-provisioned ExternalIPs
	eipList := &opv1alpha1.ExternalIPList{}
	if err := r.List(ctx, eipList,
		client.InNamespace(bareMetalInstance.Namespace),
		client.MatchingLabels{
			autoCreatedLabel:    "true",
			autoCreatedForLabel: bmiUID,
		},
	); err != nil {
		return ctrl.Result{}, false,
			fmt.Errorf("failed to list ExternalIPs: %w", err)
	}

	for i := range eipList.Items {
		eip := &eipList.Items[i]
		if eip.DeletionTimestamp.IsZero() {
			log.Info("Deleting auto-provisioned ExternalIP", "name", eip.Name)
			if err := r.Delete(ctx, eip); client.IgnoreNotFound(err) != nil {
				return ctrl.Result{}, false,
					fmt.Errorf("failed to delete ExternalIP %s: %w",
						eip.Name, err)
			}
		}
	}

	if len(eipList.Items) > 0 {
		log.Info("Waiting for ExternalIP deletion to complete",
			"remaining", len(eipList.Items))
		return ctrl.Result{
			RequeueAfter: DefaultManagementRecheckIntervalDuration,
		}, false, nil
	}

	controllerutil.RemoveFinalizer(bareMetalInstance, BareMetalInstanceCleanupFinalizer)
	if err := r.Update(ctx, bareMetalInstance); err != nil {
		return ctrl.Result{}, false, err
	}

	log.Info("Auto-cleanup completed")
	return ctrl.Result{}, true, nil
}

// addCleanupFinalizerIfNeeded adds the cleanup finalizer when auto-provisioned
// ExternalIP resources exist for this BMI. Called during reconcileManagement to
// ensure the finalizer is present before deletion can occur.
func (r *BareMetalInstanceReconciler) addCleanupFinalizerIfNeeded(
	ctx context.Context,
	bareMetalInstance *v1alpha1.BareMetalInstance,
) error {
	if controllerutil.ContainsFinalizer(bareMetalInstance, BareMetalInstanceCleanupFinalizer) {
		return nil
	}

	bmiUID := string(bareMetalInstance.UID)
	eipList := &opv1alpha1.ExternalIPList{}
	if err := r.List(ctx, eipList,
		client.InNamespace(bareMetalInstance.Namespace),
		client.MatchingLabels{
			autoCreatedLabel:    "true",
			autoCreatedForLabel: bmiUID,
		},
		client.Limit(1),
	); err != nil {
		return err
	}

	if len(eipList.Items) > 0 {
		if controllerutil.AddFinalizer(bareMetalInstance, BareMetalInstanceCleanupFinalizer) {
			return r.Update(ctx, bareMetalInstance)
		}
	}
	return nil
}
