;;; kubernetes-overview.el --- Utilities for managing the overview buffer. -*- lexical-binding: t; -*-
;;; Commentary:
;;; Code:

(require 'subr-x)

(require 'kubernetes-ast)
(require 'kubernetes-commands)
(require 'kubernetes-configmaps)
(require 'kubernetes-contexts)
(require 'kubernetes-core)
(require 'kubernetes-cronjobs)
(require 'kubernetes-deployments)
(require 'kubernetes-statefulsets)
(require 'kubernetes-nodes)
(require 'kubernetes-errors)
(require 'kubernetes-ingress)
(require 'kubernetes-jobs)
(require 'kubernetes-loading-container)
(require 'kubernetes-modes)
(require 'kubernetes-namespaces)
(require 'kubernetes-persistentvolumeclaims)
(require 'kubernetes-networkpolicies)
(require 'kubernetes-pods)
(require 'kubernetes-pod-line)
(require 'kubernetes-popups)
(require 'kubernetes-secrets)
(require 'kubernetes-services)
(require 'kubernetes-replicasets)


(autoload 'kubernetes-utils-up-to-existing-dir "kubernetes-utils")


;; Configmaps

(defun kubernetes-overview--referenced-configmaps (state pod)
  (-let* (((&alist 'items configmaps) (kubernetes-state--get state 'configmaps))
          (configmaps (append configmaps nil))
          ((&alist 'spec (&alist 'volumes volumes 'containers containers)) pod)

          (names-in-volumes
           (->> volumes
                (seq-mapcat
                 (lambda (volume)
                   (-when-let ((&alist 'configMap (&alist 'name name)) volume)
                     (list name))))))

          (names-in-env
           (->> containers
                (seq-mapcat (-lambda ((&alist 'env env)) env))
                (seq-mapcat
                 (lambda (env)
                   (-when-let ((&alist 'valueFrom (&alist 'configMapKeyRef (&alist 'name name))) env)
                     (list name))))))

          (references (-uniq (-union names-in-volumes names-in-env))))

    (seq-filter (-lambda ((&alist 'metadata (&alist 'name name)))
                  (member name references))
                configmaps)))

(defun kubernetes-overview--configmaps-for-deployment (state pods)
  (->> pods
       (seq-mapcat (lambda (pod) (kubernetes-overview--referenced-configmaps state pod)))
       -non-nil
       -uniq
       (seq-sort (lambda (s1 s2)
                   (string< (kubernetes-state-resource-name s1)
                            (kubernetes-state-resource-name s2))))))

(defun kubernetes-overview--configmaps-for-statefulset (state pods)
  (->> pods
       (seq-mapcat (lambda (pod) (kubernetes-overview--referenced-configmaps state pod)))
       -non-nil
       -uniq
       (seq-sort (lambda (s1 s2)
                   (string< (kubernetes-state-resource-name s1)
                            (kubernetes-state-resource-name s2))))))

(kubernetes-ast-define-component aggregated-configmap-line (state configmap)
  (-let* ((pending-deletion (kubernetes-state--get state 'configmaps-pending-deletion))
          (marked-configmaps (kubernetes-state--get state 'marked-configmaps))
          ((&alist 'metadata (&alist 'name name )) configmap)
          (line (cond
                 ((member name pending-deletion)
                  `(propertize (face kubernetes-pending-deletion) ,name))
                 ((member name marked-configmaps)
                  `(mark-for-delete ,name))
                 (t
                  name))))
    `(section (,(intern (kubernetes-state-resource-name configmap)) t)
              (nav-prop (:configmap-name ,name)
                        (copy-prop ,name (line ,line))))))

(kubernetes-ast-define-component aggregated-configmaps (state configmaps)
  `(section (configmaps nil)
            (heading "Configmaps")
            (indent ,(--map `(aggregated-configmap-line ,state ,it) configmaps))
            (padding)))


;; Secrets

(defun kubernetes-overview--referenced-secrets (secrets pod)
  (-let* (((&alist 'spec (&alist 'volumes vols 'containers containers)) pod)
          (combined-env (seq-mapcat (-lambda ((&alist 'env env))
                                      env)
                                    containers))
          (names-in-volumes
           (seq-mapcat
            (lambda (volume)
              (-when-let ((&alist 'secret (&alist 'secretName name)) volume)
                (list name)))
            vols))

          (names-in-env
           (seq-mapcat
            (lambda (env)
              (-when-let ((&alist 'valueFrom (&alist 'secretKeyRef (&alist 'name name))) env)
                (list name)))
            combined-env))

          (references (-union names-in-volumes names-in-env))
          (matches (seq-filter (lambda (secret)
                                 (member (kubernetes-state-resource-name secret) references))
                               secrets)))
    (seq-sort (lambda (s1 s2)
                (string< (kubernetes-state-resource-name s1)
                         (kubernetes-state-resource-name s2)))
              matches)))

(defun kubernetes-overview--secrets-for-deployment (state pods)
  (-let* (((&alist 'items secrets) (kubernetes-state--get state 'secrets))
          (secrets (append secrets nil)))
    (-non-nil (-uniq (seq-mapcat (lambda (pod)
                                   (kubernetes-overview--referenced-secrets secrets pod))
                                 pods)))))

(defun kubernetes-overview--secrets-for-statefulset (state pods)
  (-let* (((&alist 'items secrets) (kubernetes-state--get state 'secrets))
          (secrets (append secrets nil)))
    (-non-nil (-uniq (seq-mapcat (lambda (pod)
                                   (kubernetes-overview--referenced-secrets secrets pod))
                                 pods)))))

(kubernetes-ast-define-component aggregated-secret-line (state secret)
  (-let* ((pending-deletion (kubernetes-state--get state 'secrets-pending-deletion))
          (marked-secrets (kubernetes-state--get state 'marked-secrets))
          ((&alist 'metadata (&alist 'name name )) secret)
          (line (cond
                 ((member name pending-deletion)
                  `(propertize (face kubernetes-pending-deletion) ,name))
                 ((member name marked-secrets)
                  `(mark-for-delete ,name))
                 (t
                  name))))
    `(section (,(intern (kubernetes-state-resource-name secret)) t)
              (nav-prop (:secret-name ,name)
                        (copy-prop ,name (line ,line))))))

(kubernetes-ast-define-component aggregated-secrets (state secrets)
  `(section (secrets nil)
            (heading "Secrets")
            (indent ,(--map `(aggregated-secret-line ,state ,it) secrets))
            (padding)))

;; Pods

(defun kubernetes-overview--pods-for-deployment (state deployment)
  "Find pods for DEPLOYMENT in STATE using ReplicaSet UIDs in ownerReferences.
This function finds pods by identifying ReplicaSets owned by the deployment
and then finding pods owned by those ReplicaSets using UIDs exclusively."
  (let* ((deployment-uid (alist-get 'uid (alist-get 'metadata deployment)))
         (pod-items (alist-get 'items (kubernetes-state--get state 'pods)))
         (replicaset-items (alist-get 'items (kubernetes-state--get state 'replicasets))))

    (when (and deployment-uid pod-items replicaset-items)
      ;; Find ReplicaSets owned by this deployment
      (let* ((matching-replicasets
              (seq-filter
               (lambda (replicaset)
                 (let* ((owner-refs (alist-get 'ownerReferences (alist-get 'metadata replicaset))))
                   (and owner-refs
                        (seq-find
                         (lambda (ref)
                           (and (string= (alist-get 'kind ref) "Deployment")
                                (string= (alist-get 'uid ref) deployment-uid)))
                         owner-refs))))
               replicaset-items))

             ;; Collect UIDs of matching ReplicaSets
             (replicaset-uids
              (mapcar (lambda (rs) (alist-get 'uid (alist-get 'metadata rs)))
                      matching-replicasets)))

        ;; Find pods owned by those ReplicaSets using UID references
        (when replicaset-uids
          (seq-filter
           (lambda (pod)
             (let* ((owner-refs (alist-get 'ownerReferences (alist-get 'metadata pod))))
               (and owner-refs
                    (seq-find
                     (lambda (ref)
                       (and (string= (alist-get 'kind ref) "ReplicaSet")
                            (member (alist-get 'uid ref) replicaset-uids)))
                     owner-refs))))
           pod-items))))))

(defun kubernetes-overview--pods-for-statefulset (state statefulset)
  "Find pods for STATEFULSET in STATE using ownerReferences.
This function finds pods by matching the statefulset's UID with pod's ownerReferences."
  (let* ((statefulset-uid (cdr (assoc 'uid (cdr (assoc 'metadata statefulset)))))
         (pod-items (cdr (assoc 'items (kubernetes-state--get state 'pods)))))
    (when (and statefulset-uid pod-items)
      (seq-filter
       (lambda (pod)
         (let* ((owner-refs (cdr (assoc 'ownerReferences (cdr (assoc 'metadata pod))))))
           (and owner-refs
                (seq-find (lambda (ref)
                           (and (string= (cdr (assoc 'kind ref)) "StatefulSet")
                                (string= (cdr (assoc 'uid ref)) statefulset-uid)))
                         owner-refs))))
       pod-items))))


(kubernetes-ast-define-component aggregated-pods (state resource pods)
  (-let [(&alist 'spec (&alist 'replicas replicas)) resource]
    `(section (pods nil)
              (heading "Pods")
              (indent
               ;; Just show replicas count
               (key-value 12 "Replicas" ,(format "%s" (or replicas 1)))
               ;; Just list the pods directly
               (columnar-loading-container ,(kubernetes-state--get state 'pods) nil
                                           ,@(seq-map (lambda (pod) `(pod-line ,state ,pod)) pods)))
              (padding))))

;; Deployment

(kubernetes-ast-define-component aggregated-deployment-detail (deployment)
  (-let [(&alist 'metadata (&alist 'namespace ns 'creationTimestamp time)
                 'spec (&alist
                        'paused paused
                        'strategy (&alist
                                   'type strategy-type
                                   'rollingUpdate rolling-update)))
         deployment]
    `(,(when paused `(line (propertize (face warning) "Deployment Paused")))
      (section (namespace nil)
               (nav-prop (:namespace-name ,ns)
                         (key-value 12 "Namespace" ,(propertize ns 'face 'kubernetes-namespace))))
      ,(-if-let ((&alist 'maxSurge surge 'maxUnavailable unavailable) rolling-update)
           `(section (strategy t)
                     (heading (key-value 12 "Strategy" ,strategy-type))
                     (indent
                      ((key-value 12 "Max Surge" ,(format "%s" surge))
                       (key-value 12 "Max Unavailable" ,(format "%s" unavailable)))))
         `(key-value 12 "Strategy" ,strategy-type))
      (key-value 12 "Created" ,time))))

;; Statefulset

(kubernetes-ast-define-component aggregated-statefulset-detail (statefulset)
  (-let [(&alist 'metadata (&alist 'namespace ns 'creationTimestamp time)
                 'spec (&alist
                        'paused paused
                        'strategy (&alist
                                   'type _strategy-type
                                   'rollingUpdate _rolling-update)))
         statefulset]
    `(,(when paused `(line (propertize (face warning) "Statefulset Paused")))
      (section (namespace nil)
               (nav-prop (:namespace-name ,ns)
                         (key-value 12 "Namespace" ,(propertize ns 'face 'kubernetes-namespace))))
      (key-value 12 "Created" ,time))))

(kubernetes-ast-define-component aggregated-deployment (state deployment)
  (let* ((pods (kubernetes-overview--pods-for-deployment state deployment))
         (configmaps (kubernetes-overview--configmaps-for-deployment state pods))
         (secrets (kubernetes-overview--secrets-for-deployment state pods)))
    `(section (,(intern (kubernetes-state-resource-name deployment)) t)
              (heading (deployment-line ,state ,deployment))
              (section (details nil)
                       (indent
                        (aggregated-deployment-detail ,deployment)
                        (padding)
                        (aggregated-pods ,state ,deployment ,pods)
                        ,(when configmaps
                           `(aggregated-configmaps ,state ,configmaps))
                        ,(when secrets
                           `(aggregated-secrets ,state ,secrets)))))))


(kubernetes-ast-define-component aggregated-statefulset (state statefulset)
  (let* ((pods (kubernetes-overview--pods-for-statefulset state statefulset))
         (configmaps (kubernetes-overview--configmaps-for-statefulset state pods))
         (secrets (kubernetes-overview--secrets-for-statefulset state pods)))
    `(section (,(intern (kubernetes-state-resource-name statefulset)) t)
              (heading (statefulset-line ,state ,statefulset))
              (section (details nil)
                       (indent
                        (aggregated-statefulset-detail ,statefulset)
                        (padding)
                        (aggregated-pods ,state ,statefulset ,pods)
                        ,(when configmaps
                           `(aggregated-configmaps ,state ,configmaps))
                        ,(when secrets
                           `(aggregated-secrets ,state ,secrets)))))))


;; Main Components

(kubernetes-ast-define-component aggregated-view (state &optional hidden)
  (-let [(state-set-p &as &alist 'items deployments) (kubernetes-state--get state 'deployments)]
    (-let (((state-set-p &as &alist 'items statefulsets)
            (kubernetes-state--get state 'statefulsets))
           ([fmt0 labels0] kubernetes-statefulsets--column-heading)
           ([fmt1 labels1] kubernetes-deployments--column-heading))
      `(section (ubercontainer, nil)
                (section (overview-container ,hidden)
                         (header-with-count "Statefulsets" ,statefulsets)
                         (indent
                          (columnar-loading-container
                           ,statefulsets
                           ,(propertize
                             (apply #'format fmt0 (split-string labels0 "|"))
                             'face
                             'magit-section-heading)
                           ,@(--map `(aggregated-statefulset ,state ,it) statefulsets)))
                         (padding))
                (section (overview-container ,hidden)
                         (header-with-count "Deployments" ,deployments)
                         (indent
                          (columnar-loading-container
                           ,deployments
                           ,(propertize
                             (apply #'format fmt1 (split-string labels1))
                             'face
                             'magit-section-heading)
                           ,@(--map `(aggregated-deployment ,state ,it) deployments)))
                         (padding))))))

(defalias 'kubernetes-overview-render 'kubernetes--overview-render)

;; Overview buffer.

(defalias 'kubernetes-overview--redraw-buffer 'kubernetes--redraw-overview-buffer)

(defun kubernetes-overview--poll (&optional verbose)
  (let ((sections (kubernetes-state-overview-sections (kubernetes-state))))
    (when (member 'overview sections)
      (kubernetes-pods-refresh verbose)
      (kubernetes-replicasets-refresh verbose)
      (kubernetes-configmaps-refresh verbose)
      (kubernetes-secrets-refresh verbose)
      (kubernetes-statefulsets-refresh verbose)
      (kubernetes-deployments-refresh verbose))
    (when (member 'configmaps sections)
      (kubernetes-configmaps-refresh verbose))
    (when (member 'context sections)
      (kubernetes-contexts-refresh verbose))
    (when (member 'ingress sections)
      (kubernetes-ingress-refresh verbose))
    (when (member 'jobs sections)
      (kubernetes-jobs-refresh verbose))
    (when (member 'deployments sections)
      (kubernetes-deployments-refresh verbose))
    (when (member 'statefulsets sections)
      (kubernetes-statefulsets-refresh verbose))
    (when (member 'nodes sections)
      (kubernetes-nodes-refresh verbose))
    (when (member 'namespaces sections)
      (kubernetes-namespaces-refresh verbose))
    (when (member 'persistentvolumeclaims sections)
      (kubernetes-persistentvolumeclaims-refresh verbose))
    (when (member 'networkpolicies sections)
      (kubernetes-networkpolicies-refresh verbose))
    (when (member 'pods sections)
      (kubernetes-pods-refresh verbose))
    (when (member 'secrets sections)
      (kubernetes-secrets-refresh verbose))
    (when (member 'services sections)
      (kubernetes-services-refresh verbose))
    (when (member 'cronjobs sections)
      (kubernetes-cronjobs-refresh verbose))))

(defun kubernetes-overview--initialize-buffer ()
  "Called the first time the overview buffer is opened to set up the buffer."
  (let ((buf (get-buffer-create kubernetes-overview-buffer-name)))
    (with-current-buffer buf
      (kubernetes-overview-mode)
      (add-hook 'kubernetes-redraw-hook #'kubernetes-overview--redraw-buffer)
      (add-hook 'kubernetes-poll-hook #'kubernetes-overview--poll)
      (kubernetes--initialize-timers)
      (kubernetes-overview--redraw-buffer)
      (add-hook 'kill-buffer-hook (kubernetes-utils-make-cleanup-fn buf) nil t))
    buf))

(defun kubernetes-overview-set-sections (sections)
  "Set which sections are displayed in the overview.

SECTIONS is a list of sections to display.  See
`kubernetes-overview-custom-views-alist' and
`kubernetes-overview-views-alist' for possible values."
  (interactive
   (let* ((views (append kubernetes-overview-custom-views-alist kubernetes-overview-views-alist))
          (names (-uniq (--map (symbol-name (car it)) views)))
          (choice (intern (completing-read "Overview view: " names nil t))))
     (list (alist-get choice views))))

  (kubernetes-state-update-overview-sections sections)
  (kubernetes-state-trigger-redraw))

(defvar kubernetes-overview-mode-map
  (let ((keymap (make-sparse-keymap)))
    (define-key keymap (kbd "v") #'kubernetes-overview-set-sections)
    keymap)
  "Keymap for `kubernetes-overview-mode'.")

;;;###autoload
(define-derived-mode kubernetes-overview-mode kubernetes-mode "Kubernetes Overview"
  "Mode for working with Kubernetes overview.

\\<kubernetes-overview-mode-map>\
Type \\[kubernetes-overview-set-sections] to choose which resources to display.

Type \\[kubernetes-mark-for-delete] to mark an object for deletion, and \\[kubernetes-execute-marks] to execute.
Type \\[kubernetes-unmark] to unmark the object at point, or \\[kubernetes-unmark-all] to unmark all objects.

Type \\[kubernetes-navigate] to inspect the object on the current line.

Type \\[kubernetes-copy-thing-at-point] to copy the thing at point.

Type \\[kubernetes-refresh] to refresh the buffer.

\\{kubernetes-overview-mode-map}"
  :group 'kubernetes)

;;;###autoload
(defun kubernetes-overview ()
  "Display an overview buffer for Kubernetes."
  (interactive)
  (unless (executable-find kubernetes-kubectl-executable)
    (error "Executable for `kubectl' not found on PATH; make sure `kubernetes-kubectl-executable' is valid"))
  (let ((dir default-directory)
        (buf (kubernetes-overview--initialize-buffer)))
    (when kubernetes-default-overview-namespace
      (kubernetes-set-namespace kubernetes-default-overview-namespace
				(kubernetes-state)))
    (kubernetes-commands-display-buffer buf)
    (with-current-buffer buf
      (cd (kubernetes-utils-up-to-existing-dir dir)))
    (message (substitute-command-keys "\\<kubernetes-overview-mode-map>Type \\[kubernetes-overview-set-sections] to switch between resources, and \\[kubernetes-dispatch] for usage."))))

(provide 'kubernetes-overview)

;;; kubernetes-overview.el ends here
