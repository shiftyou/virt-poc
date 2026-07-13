#!/bin/bash
# =============================================================================
# 14-oadp.sh
#
# OADP 실습 환경 구성
#   1. OADP Operator namespace 확인 (기본값: openshift-adp)
#   2. ObjectBucketClaim 생성 및 버킷/자격 증명 획득 (ODF 백엔드 전용)
#   3. cloud-credentials Secret 생성
#   4. VolumeSnapshotClass YAML 생성 (CSI 스냅샷용, 스토리지 환경에 맞게 적용)
#   5. DataProtectionApplication 배포
#   6. BackupStorageLocation 확인
#   7. poc-oadp namespace 생성
#   8. poc-oadp VM 생성 (poc DataSource 사용)
#   9. Backup CR 생성 (poc-oadp 백업) + Restore YAML 생성 (적용하지 않음)
#
# 요구 사항:
#   - OADP Operator가 설치되어 있어야 합니다 (기본 namespace: openshift-adp)
#   - 백엔드: Garage가 배포 및 구성되어 있거나, ODF Operator가 설치되어 있어야 합니다
#
# 사용법: ./14-oadp.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

NS="${OADP_NS:-openshift-adp}"

# 사용할 백엔드: garage | odf (preflight에서 결정)
BACKEND=""

# 통합 S3 변수 (백엔드에 따라 preflight에서 설정)
S3_ENDPOINT=""
S3_BUCKET=""
S3_ACCESS_KEY=""
S3_SECRET_KEY=""
S3_REGION=""
DPA_NAME="poc-dpa"
BSL_NAME="poc-dpa-1"

source "${SCRIPT_DIR}/../utils/common.sh"

GARAGE_DEFAULT_IMAGE="dxflrs/garage:v1.0.1"

install_garage() {
    echo ""
    print_warn "클러스터에서 Garage S3 서비스를 찾을 수 없습니다."
    read -r -p "  Garage S3 스토리지를 자동 설치하시겠습니까? (Y/n): " _ans
    if [[ "${_ans:-}" =~ ^[Nn]$ ]]; then
        return 1
    fi

    local garage_image="${GARAGE_DEFAULT_IMAGE}"
    read -r -p "  Garage 컨테이너 이미지 [${garage_image}]: " _input
    [ -n "$_input" ] && garage_image="$_input"
    print_info "사용할 이미지: ${garage_image}"

    # Namespace
    if oc get namespace poc-garage &>/dev/null; then
        print_ok "Namespace poc-garage 이미 존재합니다 — 건너뜀"
    else
        oc new-project poc-garage > /dev/null
        print_ok "Namespace poc-garage 생성됨"
    fi

    # SCC
    oc adm policy add-scc-to-user anyuid -z default -n poc-garage &>/dev/null
    print_ok "poc-garage의 default SA에 anyuid SCC 부여됨"

    # 리소스 배포
    print_info "Garage 리소스 배포 중..."
    oc apply -f - <<EOF
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: garage-data
  namespace: poc-garage
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: garage-meta
  namespace: poc-garage
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Secret
metadata:
  name: garage-credentials
  namespace: poc-garage
type: Opaque
stringData:
  accessKey: "garageadmin"
  secretKey: "garageadmin"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: garage-config
  namespace: poc-garage
data:
  garage.toml: |
    metadata_dir = "/meta"
    data_dir = "/data"

    replication_factor = 1

    rpc_bind_addr = "[::]:3901"
    rpc_public_addr = "127.0.0.1:3901"
    rpc_secret = "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"

    [s3_api]
    s3_region = "garage"
    api_bind_addr = "[::]:3900"
    root_domain = ".s3.garage.localhost"

    [s3_web]
    bind_addr = "[::]:3902"
    root_domain = ".web.garage.localhost"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: garage
  namespace: poc-garage
spec:
  replicas: 1
  selector:
    matchLabels:
      app: garage
  template:
    metadata:
      labels:
        app: garage
    spec:
      containers:
        - name: garage
          image: ${garage_image}
          env:
            - name: GARAGE_RPC_SECRET
              value: "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
          ports:
            - containerPort: 3900
              name: s3-api
            - containerPort: 3902
              name: web
          volumeMounts:
            - name: data
              mountPath: /data
            - name: meta
              mountPath: /meta
            - name: config
              mountPath: /etc/garage.toml
              subPath: garage.toml
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: garage-data
        - name: meta
          persistentVolumeClaim:
            claimName: garage-meta
        - name: config
          configMap:
            name: garage-config
---
apiVersion: v1
kind: Service
metadata:
  name: garage
  namespace: poc-garage
  labels:
    app: garage
spec:
  selector:
    app: garage
  ports:
    - name: s3-api
      port: 3900
      targetPort: 3900
    - name: web
      port: 3902
      targetPort: 3902
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: garage-api
  namespace: poc-garage
spec:
  to:
    kind: Service
    name: garage
  port:
    targetPort: s3-api
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
EOF
    print_ok "Garage 리소스 배포 완료"

    # Pod 대기
    print_info "Garage Pod 준비 대기 중..."
    if ! oc wait --for=condition=ready pod -l app=garage -n poc-garage --timeout=300s 2>/dev/null; then
        print_error "Garage Pod 시작 실패. 확인: oc get pods -n poc-garage"
        return 1
    fi
    print_ok "Garage Pod 준비됨"

    # 레이아웃 구성 및 버킷 생성
    local garage_pod node_id
    garage_pod=$(oc get pod -n poc-garage -l app=garage -o jsonpath='{.items[0].metadata.name}')

    local id_output
    id_output=$(oc exec -n poc-garage "$garage_pod" -- /garage node id 2>&1 || true)
    # "@" 앞의 hex 노드 ID 추출
    node_id=$(echo "$id_output" | grep -oE '[0-9a-f]+@' | head -1 | sed 's/@//')

    if [ -z "$node_id" ]; then
        print_error "Garage 노드 ID를 가져올 수 없습니다"
        print_error "  출력: ${id_output}"
        return 1
    fi
    print_info "Garage 노드 ID: ${node_id}"

    oc exec -n poc-garage "$garage_pod" -- /garage layout assign -z dc1 -c 1G "$node_id" 2>&1 || true
    oc exec -n poc-garage "$garage_pod" -- /garage layout apply --version 1 2>&1 || true
    print_ok "Garage 레이아웃 구성 완료"

    # API 키 생성 (Garage가 GK 접두사 access key + secret 생성)
    local key_output gk_access gk_secret
    key_output=$(oc exec -n poc-garage "$garage_pod" -- /garage key create garageadmin 2>&1 || true)
    gk_access=$(echo "$key_output" | grep -i "Key ID" | awk '{print $NF}')
    gk_secret=$(echo "$key_output" | grep -i "Secret" | awk '{print $NF}')

    if [ -z "$gk_access" ] || [ -z "$gk_secret" ]; then
        print_warn "키 생성 출력:"
        echo "$key_output"
        print_warn "Garage 키 파싱 실패 — Secret의 기본값 사용"
    else
        print_info "Garage 키 ID: ${gk_access}"
        # 실제 Garage 생성 자격 증명으로 Secret 업데이트
        oc create secret generic garage-credentials -n poc-garage \
            --from-literal=accessKey="$gk_access" \
            --from-literal=secretKey="$gk_secret" \
            --dry-run=client -o yaml | oc apply -f - 2>/dev/null
    fi

    # 버킷 생성 및 접근 권한 부여
    oc exec -n poc-garage "$garage_pod" -- /garage bucket create velero 2>&1 || true
    oc exec -n poc-garage "$garage_pod" -- /garage bucket allow --read --write velero --key garageadmin 2>&1 || true
    print_ok "버킷 'velero' 생성 및 접근 권한 부여됨"

    print_ok "Garage S3 설치 완료"
    return 0
}

preflight() {
    print_step "사전 점검"

    if ! oc whoami &>/dev/null; then
        print_error "OpenShift에 로그인되어 있지 않습니다."
        exit 1
    fi
    print_ok "클러스터 연결: $(oc whoami) @ $(oc whoami --show-server)"

    # OADP Operator 필수
    if [ "${OADP_INSTALLED:-false}" != "true" ]; then
        print_warn "OADP Operator 설치되어 있지 않습니다 → 건너뜀."
        print_warn "  설치 가이드: operators/oadp-operator.md"
        exit 77
    fi
    print_ok "OADP Operator 확인됨 (ns: ${NS})"

    # 초기 S3 값 결정: Garage 우선, 다음 ODF, 그 다음 비어 있음 (수동 입력)
    # env.conf에 S3 정보가 없으면 클러스터에서 자동 감지
    if [ "${GARAGE_INSTALLED:-false}" = "true" ] && [ -n "${GARAGE_ENDPOINT:-}" ]; then
        BACKEND="garage"
        S3_ENDPOINT="${GARAGE_ENDPOINT}"
        S3_BUCKET="${OADP_S3_BUCKET:-${GARAGE_BUCKET:-velero}}"
        S3_ACCESS_KEY="${GARAGE_ACCESS_KEY:-}"
        S3_SECRET_KEY="${GARAGE_SECRET_KEY:-}"
        S3_REGION="${OADP_S3_REGION:-garage}"
    elif [ -z "${GARAGE_ENDPOINT:-}" ]; then
        # env.conf에 Garage 정보 없음 — 라이브 감지 시도
        auto_detect_garage
        if [ "${GARAGE_FOUND}" != "true" ]; then
            if install_garage; then
                auto_detect_garage
            fi
        fi
        if [ "${GARAGE_FOUND}" = "true" ]; then
            BACKEND="garage"
            S3_ENDPOINT="${GARAGE_ENDPOINT}"
            S3_BUCKET="${OADP_S3_BUCKET:-${GARAGE_BUCKET:-velero}}"
            S3_ACCESS_KEY="${GARAGE_ACCESS_KEY:-}"
            S3_SECRET_KEY="${GARAGE_SECRET_KEY:-}"
            S3_REGION="${OADP_S3_REGION:-garage}"
        elif [ "${ODF_INSTALLED:-false}" = "true" ]; then
            auto_detect_odf
            if [ -n "${ODF_S3_ACCESS_KEY:-}" ]; then
                BACKEND="odf"
                S3_ENDPOINT="${ODF_S3_ENDPOINT}"
                S3_BUCKET="(OBC 자동 생성 — step_obc에서 결정)"
                S3_ACCESS_KEY="${ODF_S3_ACCESS_KEY:-}"
                S3_SECRET_KEY="${ODF_S3_SECRET_KEY:-}"
                S3_REGION="${OADP_S3_REGION:-${ODF_S3_REGION:-us-east-1}}"
            else
                BACKEND="custom"
                S3_ENDPOINT="${OADP_S3_ENDPOINT:-}"
                S3_BUCKET="${OADP_S3_BUCKET:-velero}"
                S3_ACCESS_KEY="${OADP_S3_ACCESS_KEY:-}"
                S3_SECRET_KEY="${OADP_S3_SECRET_KEY:-}"
                S3_REGION="${OADP_S3_REGION:-us-east-1}"
                print_warn "Object Storage 자동 감지 실패 — 아래에 값을 입력하세요."
            fi
        else
            BACKEND="custom"
            S3_ENDPOINT="${OADP_S3_ENDPOINT:-}"
            S3_BUCKET="${OADP_S3_BUCKET:-velero}"
            S3_ACCESS_KEY="${OADP_S3_ACCESS_KEY:-}"
            S3_SECRET_KEY="${OADP_S3_SECRET_KEY:-}"
            S3_REGION="${OADP_S3_REGION:-us-east-1}"
            print_warn "Object Storage 자동 감지 실패 — 아래에 값을 입력하세요."
        fi
    elif [ "${ODF_INSTALLED:-false}" = "true" ] && [ -n "${ODF_S3_ENDPOINT:-}" ]; then
        BACKEND="odf"
        S3_ENDPOINT="${ODF_S3_ENDPOINT}"
        S3_BUCKET="(OBC 자동 생성 — step_obc에서 결정)"
        S3_ACCESS_KEY="${ODF_S3_ACCESS_KEY:-}"
        S3_SECRET_KEY="${ODF_S3_SECRET_KEY:-}"
        S3_REGION="${OADP_S3_REGION:-${ODF_S3_REGION:-us-east-1}}"
    else
        BACKEND="custom"
        S3_ENDPOINT="${OADP_S3_ENDPOINT:-}"
        S3_BUCKET="${OADP_S3_BUCKET:-velero}"
        S3_ACCESS_KEY="${OADP_S3_ACCESS_KEY:-}"
        S3_SECRET_KEY="${OADP_S3_SECRET_KEY:-}"
        S3_REGION="${OADP_S3_REGION:-us-east-1}"
        print_warn "Object Storage 자동 감지 실패 — 아래에 값을 입력하세요."
    fi

    echo ""
    print_info "── Object Storage (S3) — OADP 백업용 ──"
    print_info "  Backend     : ${BACKEND}"
    print_info "  S3 Endpoint : ${S3_ENDPOINT:-(미설정)}"
    print_info "  S3 Bucket   : ${S3_BUCKET}"
    print_info "  S3 Region   : ${S3_REGION}"
    print_info "  S3 AccessKey: ${S3_ACCESS_KEY:-(미설정)}"
    print_info "  S3 SecretKey: ****"
    echo ""
    read -r -p "  위 정보가 맞습니까? (Y/n): " _confirm
    if [[ "${_confirm:-}" =~ ^[Nn]$ ]]; then
        read -r -p "  S3 Endpoint  [${S3_ENDPOINT}]: " _input
        [ -n "$_input" ] && S3_ENDPOINT="$_input"
        read -r -p "  S3 Bucket    [${S3_BUCKET}]: " _input
        [ -n "$_input" ] && S3_BUCKET="$_input"
        read -r -p "  S3 Region    [${S3_REGION}]: " _input
        [ -n "$_input" ] && S3_REGION="$_input"
        read -r -p "  S3 AccessKey [${S3_ACCESS_KEY}]: " _input
        [ -n "$_input" ] && S3_ACCESS_KEY="$_input"
        read -r -s -p "  S3 SecretKey [****]: " _input
        echo ""
        [ -n "$_input" ] && S3_SECRET_KEY="$_input"
    fi

    if [ -z "${S3_ENDPOINT}" ] || [ -z "${S3_ACCESS_KEY}" ]; then
        print_error "S3 Endpoint 또는 AccessKey가 비어 있습니다."
        exit 1
    fi
    print_ok "Object Storage 구성 확인됨 (backend: ${BACKEND}, bucket: ${S3_BUCKET})"

    # 다른 실습에서 재사용하기 위해 S3 구성을 env.conf에 저장 (예: 20-logging)
    save_to_env "GARAGE_INSTALLED" "${GARAGE_FOUND:-false}"
    save_to_env "GARAGE_ENDPOINT" "${GARAGE_ENDPOINT:-${S3_ENDPOINT}}"
    save_to_env "GARAGE_BUCKET" "${GARAGE_BUCKET:-${S3_BUCKET}}"
    save_to_env "GARAGE_ACCESS_KEY" "${GARAGE_ACCESS_KEY:-${S3_ACCESS_KEY}}"
    save_to_env "GARAGE_SECRET_KEY" "${GARAGE_SECRET_KEY:-${S3_SECRET_KEY}}"
    save_to_env "ODF_S3_ENDPOINT" "${ODF_S3_ENDPOINT:-}"
    save_to_env "ODF_S3_ACCESS_KEY" "${ODF_S3_ACCESS_KEY:-}"
    save_to_env "ODF_S3_SECRET_KEY" "${ODF_S3_SECRET_KEY:-}"
    save_to_env "ODF_S3_REGION" "${ODF_S3_REGION:-us-east-1}"
    save_to_env "OADP_S3_BUCKET" "${S3_BUCKET}"
    save_to_env "OADP_S3_REGION" "${S3_REGION}"
}

# =============================================================================
# Step 1: namespace 확인 (OADP Operator 설치 namespace)
# =============================================================================
step_namespace() {
    print_step "1/6  namespace 확인 (${NS})"

    if oc get namespace "$NS" &>/dev/null; then
        print_ok "Namespace $NS 확인됨"
    else
        print_error "Namespace $NS 찾을 수 없습니다 — OADP Operator가 설치되어 있는지 확인하세요."
        print_error "  설치 가이드: operators/oadp-operator.md"
        exit 1
    fi
}

# =============================================================================
# Step 2: ObjectBucketClaim 생성 및 버킷/자격 증명 획득 (ODF 백엔드 전용)
# =============================================================================
step_obc() {
    if [ "$BACKEND" != "odf" ]; then
        print_step "2/6  OBC — Garage 백엔드, 건너뜀"
        return
    fi

    print_step "2/6  ObjectBucketClaim 생성 (ns: ${NS})"

    # NooBaa StorageClass 자동 감지
    local obc_sc
    obc_sc=$(oc get storageclass -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | \
        tr ' ' '\n' | grep -i "noobaa" | head -1 || true)
    if [ -z "$obc_sc" ]; then
        obc_sc="openshift-storage.noobaa.io"
        print_warn "NooBaa StorageClass 자동 감지 실패 → 기본값 사용: ${obc_sc}"
    else
        print_info "OBC StorageClass: ${obc_sc}"
    fi

    if oc get obc obc-backups -n "$NS" &>/dev/null; then
        print_ok "ObjectBucketClaim obc-backups 이미 존재합니다 — 건너뜀"
    else
        cat > obc-backups.yaml <<EOF
apiVersion: objectbucket.io/v1alpha1
kind: ObjectBucketClaim
metadata:
  name: obc-backups
  namespace: ${NS}
spec:
  generateBucketName: backups
  storageClassName: ${obc_sc}
EOF
        echo "생성된 파일: obc-backups.yaml"
        oc apply -f obc-backups.yaml
        print_ok "ObjectBucketClaim obc-backups 성공적으로 생성됨 → ns: ${NS}"
    fi

    # Bound 대기
    print_info "OBC Bound 대기 중..."
    local retries=12
    local i=0
    while [ $i -lt $retries ]; do
        local phase
        phase=$(oc get obc obc-backups -n "$NS" \
            -o jsonpath='{.status.phase}' 2>/dev/null || true)
        if [ "$phase" = "Bound" ]; then
            print_ok "OBC 상태: Bound"
            break
        fi
        printf "  [%d/%d] 대기 중... (%s)\r" "$((i+1))" "$retries" "${phase:-Pending}"
        sleep 5
        i=$((i+1))
    done
    echo ""

    if [ $i -eq $retries ]; then
        print_error "OBC Bound 시간 초과. ODF/NooBaa 상태를 확인하세요."
        exit 1
    fi

    # ConfigMap에서 버킷 이름 가져오기
    # S3_ENDPOINT와 S3_REGION은 env.conf의 값 유지 (ODF_S3_ENDPOINT/REGION)
    S3_BUCKET=$(oc get cm obc-backups -n "$NS" \
        -o jsonpath='{.data.BUCKET_NAME}' 2>/dev/null || true)

    # Secret에서 버킷별 자격 증명 가져오기 (noobaa-admin 대신)
    S3_ACCESS_KEY=$(oc get secret obc-backups -n "$NS" \
        -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' 2>/dev/null | base64 -d || true)
    S3_SECRET_KEY=$(oc get secret obc-backups -n "$NS" \
        -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' 2>/dev/null | base64 -d || true)

    print_ok "OBC 버킷/자격 증명 획득 성공"
    print_info "  Bucket   : ${S3_BUCKET}"
    print_info "  Endpoint : ${S3_ENDPOINT}"
    print_info "  Region   : ${S3_REGION}"
    print_info "  AccessKey: ${S3_ACCESS_KEY}"
}

# =============================================================================
# Step 3: cloud-credentials Secret 생성 (OADP Operator namespace)
# =============================================================================
step_credentials() {
    print_step "3/6  cloud-credentials Secret 생성 (backend: ${BACKEND}, ns: ${NS})"

    cat > cloud-credentials-secret.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: cloud-credentials
  namespace: ${NS}
stringData:
  cloud: |
    [default]
    aws_access_key_id=${S3_ACCESS_KEY}
    aws_secret_access_key=${S3_SECRET_KEY}
EOF
    confirm_and_apply cloud-credentials-secret.yaml
    print_ok "cloud-credentials Secret 성공적으로 생성됨 → ns: ${NS}"
}

# =============================================================================
# Step 4: VolumeSnapshotClass YAML 생성 (CSI 스냅샷용)
# =============================================================================
step_volumesnapshotclass() {
    print_step "4/6  VolumeSnapshotClass YAML 생성"

    # 클러스터의 CSI 드라이버 자동 감지
    local csi_driver
    csi_driver=$(oc get csidrivers -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | \
        tr ' ' '\n' | grep -v "^kubernetes\|^csi-snapshot\|^file" | head -1 || true)

    if [ -z "$csi_driver" ]; then
        csi_driver="your.csi.driver.com"
        print_warn "CSI 드라이버 자동 감지 실패 → 기본값 사용: ${csi_driver}"
        print_warn "  실제 드라이버 이름으로 업데이트하여 적용하세요: oc get csidrivers"
    else
        print_info "CSI 드라이버 감지됨: ${csi_driver}"
    fi

    cat > volumesnapshotclass.yaml <<EOF
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: poc-volumesnapshotclass
  labels:
    velero.io/csi-volumesnapshot-class: "true"
driver: ${csi_driver}
deletionPolicy: Delete
EOF
    echo "생성된 파일: volumesnapshotclass.yaml"
    print_info "CSI 스냅샷을 사용하려면 다음 명령으로 적용하세요:"
    echo -e "    ${CYAN}oc apply -f volumesnapshotclass.yaml${NC}"
}

# =============================================================================
# Step 5: DataProtectionApplication 배포 (OADP Operator namespace)
# =============================================================================
step_dpa() {
    print_step "5/6  DataProtectionApplication 배포 (backend: ${BACKEND}, ns: ${NS})"

    # OADP는 namespace당 하나의 DPA만 허용 — DPA가 이미 존재하면 버킷/자격 증명 업데이트
    local _existing_dpa
    _existing_dpa=$(oc get dpa -n "$NS" --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | head -1 || true)
    if [ -n "$_existing_dpa" ] && [ "$_existing_dpa" != "poc-dpa" ]; then
        print_warn "DPA '${_existing_dpa}' 이미 존재합니다 (OADP는 namespace당 하나의 DPA만 허용합니다)."
        DPA_NAME="${_existing_dpa}"
        BSL_NAME="${_existing_dpa}-1"
        print_info "기존 DPA '${_existing_dpa}'의 버킷/엔드포인트/자격 증명 업데이트 중."

        oc patch dpa "${_existing_dpa}" -n "$NS" --type=json -p="[
          {\"op\":\"replace\",\"path\":\"/spec/backupLocations/0/velero/objectStorage/bucket\",\"value\":\"${S3_BUCKET}\"},
          {\"op\":\"replace\",\"path\":\"/spec/backupLocations/0/velero/config/s3Url\",\"value\":\"${S3_ENDPOINT}\"},
          {\"op\":\"replace\",\"path\":\"/spec/backupLocations/0/velero/config/region\",\"value\":\"${S3_REGION}\"}
        ]" 2>/dev/null && print_ok "DPA 버킷/엔드포인트/리전 업데이트 성공" || \
            print_warn "DPA 패치 실패 — 수동 확인 필요: oc edit dpa ${_existing_dpa} -n ${NS}"
        return
    fi

    if oc get dpa poc-dpa -n "$NS" &>/dev/null; then
        print_ok "DataProtectionApplication poc-dpa 이미 존재합니다 — 건너뜀"
        return
    fi

    cat > poc-dpa.yaml <<EOF
apiVersion: oadp.openshift.io/v1alpha1
kind: DataProtectionApplication
metadata:
  name: poc-dpa
  namespace: ${NS}
spec:
  configuration:
    nodeAgent:
      enable: true
      uploaderType: restic
    velero:
      defaultPlugins:
        - aws
        - openshift
        - kubevirt
        - csi
      disableFsBackup: false
  logFormat: text
  backupLocations:
    - velero:
        provider: aws
        default: true
        objectStorage:
          bucket: ${S3_BUCKET}
          prefix: oadp
        config:
          profile: default
          region: ${S3_REGION}
          s3ForcePathStyle: "true"
          s3Url: ${S3_ENDPOINT}
          checksumAlgorithm: ""
        credential:
          key: cloud
          name: cloud-credentials
EOF
    confirm_and_apply poc-dpa.yaml
    print_ok "DataProtectionApplication poc-dpa 성공적으로 배포됨 → ns: ${NS}"
}

# =============================================================================
# Step 6: BackupStorageLocation 확인
# =============================================================================
step_verify() {
    print_step "6/6  BackupStorageLocation 확인 (ns: ${NS})"

    # DPA_NAME/BSL_NAME은 step_dpa()에서 결정됨 (기존 DPA 재사용 시 변경될 수 있음)

    echo ""
    # namespace에 다른 DPA/BSL이 있는지 경고
    local other_bsl
    other_bsl=$(oc get backupstoragelocation -n "$NS" \
        --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | grep -v "^${BSL_NAME}$" || true)
    if [ -n "$other_bsl" ]; then
        print_warn "다른 BackupStorageLocation이 감지되었습니다:"
        echo "$other_bsl" | while read -r b; do
            print_warn "  - ${b} (이 스크립트에서 생성하지 않음, 상태 무관)"
        done
        echo ""
    fi

    print_info "연결 대상 정보 (BSL: ${BSL_NAME}):"
    print_info "  S3 Endpoint : ${S3_ENDPOINT}"
    print_info "  S3 Bucket   : ${S3_BUCKET}"
    print_info "  S3 Region   : ${S3_REGION}"
    echo ""
    print_warn "참고: BSL 검증 실패의 일반적인 원인"
    print_warn "  1) 버킷이 존재하지 않습니다 — Velero는 버킷을 자동 생성하지 않습니다."
    if [ "$BACKEND" = "odf" ]; then
        print_warn "     ODF: OBC(obc-backups)가 생성한 버킷 이름 사용 → ${S3_BUCKET}"
    else
        print_warn "     Garage: 'garage bucket create ${S3_BUCKET}' 명령으로 버킷 생성 또는 14-oadp.md 참조"
    fi
    print_warn "  2) Endpoint에 연결할 수 없습니다 — Velero Pod가 ${S3_ENDPOINT}에 접근 가능해야 합니다."
    print_warn "  3) 자격 증명 오류 — AccessKey / SecretKey를 확인하세요"
    echo ""

    print_info "BackupStorageLocation 준비 대기 중 (BSL: ${BSL_NAME})..."
    local retries=18
    local i=0
    while [ $i -lt $retries ]; do
        local phase err_msg
        phase=$(oc get backupstoragelocation "${BSL_NAME}" -n "$NS" \
            -o jsonpath='{.status.phase}' 2>/dev/null || true)
        if [ "$phase" = "Available" ]; then
            print_ok "BackupStorageLocation ${BSL_NAME} 상태: Available"
            oc get backupstoragelocation -n "$NS" 2>/dev/null || true
            return
        fi
        err_msg=$(oc get backupstoragelocation "${BSL_NAME}" -n "$NS" \
            -o jsonpath='{.status.message}' 2>/dev/null || true)
        printf "  [%d/%d] 상태: %-12s %s\r" "$((i+1))" "$retries" "${phase:-Pending}" "${err_msg:+| $err_msg}"
        sleep 10
        i=$((i+1))
    done
    echo ""

    print_warn "BackupStorageLocation 준비 시간 초과."
    echo ""
    print_info "현재 BSL 상태:"
    oc get backupstoragelocation -n "$NS" 2>/dev/null || true
    echo ""
    print_info "상세 오류 확인 (${BSL_NAME}):"
    oc describe backupstoragelocation "${BSL_NAME}" -n "$NS" 2>/dev/null | grep -A5 "Status:\|Message:\|Phase:" || true
    echo ""
    print_info "  → oc describe backupstoragelocation ${BSL_NAME} -n ${NS}"
}

# =============================================================================
# Step 7: poc-oadp namespace 생성 (백업 대상)
# =============================================================================
VM_NS="poc-oadp"

step_vm_namespace() {
    print_step "7/9  백업 대상 namespace 생성 (${VM_NS})"

    if oc get namespace "$VM_NS" &>/dev/null; then
        print_ok "Namespace $VM_NS 이미 존재합니다 — 건너뜀"
    else
        oc new-project "$VM_NS" > /dev/null
        print_ok "Namespace $VM_NS 성공적으로 생성됨"
    fi
}

# =============================================================================
# Step 8: VM 생성 (poc-oadp, poc DataSource 사용)
# =============================================================================
step_vm() {
    print_step "8/9  VM 생성 (ns: ${VM_NS})"

    if oc get vm poc-oadp-vm -n "$VM_NS" &>/dev/null; then
        print_ok "VM poc-oadp-vm 이미 존재합니다 — 건너뜀"
        return
    fi

    if ! oc get template poc -n openshift &>/dev/null; then
        print_warn "poc Template을 찾을 수 없습니다 — VM 생성 건너뜀. (먼저 01-template을 실행하세요)"
        return
    fi

    local vm_yaml="${SCRIPT_DIR}/poc-oadp-vm.yaml"
    oc process -n openshift poc -p NAME="poc-oadp-vm" | \
        sed 's/  running: false/  runStrategy: Always/' > "${vm_yaml}"
    echo "생성된 파일: ${vm_yaml}"
    confirm_and_apply "${vm_yaml}"
    print_ok "VM poc-oadp-vm 성공적으로 생성됨 → ns: ${VM_NS}"
    print_info "  VM 상태 확인: oc get vm -n ${VM_NS}"
}

# =============================================================================
# Step 9: Backup CR 생성 + Restore YAML 생성 (적용하지 않음)
# =============================================================================
step_backup() {
    print_step "9/9  Backup CR 생성 (대상: ${VM_NS}, ns: ${NS})"

    # BSL 이름 동적 감지 (OADP Operator가 DPA 이름 기반으로 자동 생성, 예: poc-dpa-1)
    local bsl_name
    bsl_name=$(oc get backupstoragelocation -n "$NS" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "default")
    print_info "BackupStorageLocation: ${bsl_name}"

    if oc get backup poc-oadp-backup -n "$NS" &>/dev/null; then
        print_ok "Backup poc-oadp-backup 이미 존재합니다 — 건너뜀"
    else
        cat > poc-oadp-backup.yaml <<EOF
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: poc-oadp-backup
  namespace: ${NS}
spec:
  includedNamespaces:
    - ${VM_NS}
  storageLocation: ${bsl_name}
  ttl: 720h0m0s
  snapshotVolumes: true
EOF
        confirm_and_apply poc-oadp-backup.yaml
        print_ok "Backup poc-oadp-backup 성공적으로 생성됨 → ns: ${NS}"
    fi

    # Restore YAML 생성 (적용하지 않음)
    cat > poc-oadp-restore.yaml <<EOF
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: poc-oadp-restore
  namespace: ${NS}
spec:
  backupName: poc-oadp-backup
  includedNamespaces:
    - ${VM_NS}
  restorePVs: true
EOF
    echo "생성된 파일: poc-oadp-restore.yaml"
    print_info "복원하려면 다음 명령으로 적용하세요:"
    echo -e "    ${CYAN}oc apply -f poc-oadp-restore.yaml${NC}"
}

step_consoleyamlsamples() {
    print_step "10/10  ConsoleYAMLSample 등록"

    cat > consoleyamlsample-dpa.yaml <<EOF
apiVersion: console.openshift.io/v1
kind: ConsoleYAMLSample
metadata:
  name: poc-dataprotectionapplication
spec:
  title: "POC DataProtectionApplication (OADP)"
  description: "S3 호환 Object Storage(Garage/ODF)를 백업 스토리지로 사용하는 DataProtectionApplication 예제. kubevirt, csi, openshift 플러그인 포함."
  targetResource:
    apiVersion: oadp.openshift.io/v1alpha1
    kind: DataProtectionApplication
  yaml: |
    apiVersion: oadp.openshift.io/v1alpha1
    kind: DataProtectionApplication
    metadata:
      name: poc-dpa
      namespace: ${NS}
    spec:
      configuration:
        nodeAgent:
          enable: true
          uploaderType: restic
        velero:
          defaultPlugins:
            - aws
            - openshift
            - kubevirt
            - csi
          disableFsBackup: false
      logFormat: text
      backupLocations:
        - velero:
            provider: aws
            default: true
            objectStorage:
              bucket: velero
              prefix: oadp
            config:
              profile: default
              region: us-east-1
              s3ForcePathStyle: "true"
              s3Url: http://garage.garage.svc:3900
              checksumAlgorithm: ""
            credential:
              key: cloud
              name: cloud-credentials
EOF
    oc apply -f consoleyamlsample-dpa.yaml
    print_ok "ConsoleYAMLSample poc-dataprotectionapplication 성공적으로 등록됨"

    cat > consoleyamlsample-backup.yaml <<EOF
apiVersion: console.openshift.io/v1
kind: ConsoleYAMLSample
metadata:
  name: poc-backup
spec:
  title: "POC Backup (Velero)"
  description: "특정 namespace의 VM과 볼륨을 백업하기 위한 Velero Backup CR 예제. storageLocation에 DataProtectionApplication이 자동 생성한 BSL 이름을 사용합니다."
  targetResource:
    apiVersion: velero.io/v1
    kind: Backup
  yaml: |
    apiVersion: velero.io/v1
    kind: Backup
    metadata:
      name: poc-oadp-backup
      namespace: ${NS}
    spec:
      includedNamespaces:
        - poc-oadp
      storageLocation: poc-dpa-1
      ttl: 720h0m0s
      snapshotVolumes: true
EOF
    oc apply -f consoleyamlsample-backup.yaml
    print_ok "ConsoleYAMLSample poc-backup 성공적으로 등록됨"

    cat > consoleyamlsample-restore.yaml <<EOF
apiVersion: console.openshift.io/v1
kind: ConsoleYAMLSample
metadata:
  name: poc-restore
spec:
  title: "POC Restore (Velero)"
  description: "Velero Backup에서 VM과 PV를 복원하기 위한 Restore CR 예제. 백업 완료 후 적용하세요."
  targetResource:
    apiVersion: velero.io/v1
    kind: Restore
  yaml: |
    apiVersion: velero.io/v1
    kind: Restore
    metadata:
      name: poc-oadp-restore
      namespace: ${NS}
    spec:
      backupName: poc-oadp-backup
      includedNamespaces:
        - poc-oadp
      restorePVs: true
EOF
    oc apply -f consoleyamlsample-restore.yaml
    print_ok "ConsoleYAMLSample poc-restore 성공적으로 등록됨"
}

print_summary() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  완료! OADP 실습 환경이 준비되었습니다.${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  Backend : ${BACKEND}"
    echo ""
    echo -e "  BackupStorageLocation 확인:"
    echo -e "    ${CYAN}oc get backupstoragelocation -n ${NS}${NC}"
    echo ""
    echo -e "  VM 상태 확인 (백업 대상):"
    echo -e "    ${CYAN}oc get vm -n ${VM_NS}${NC}"
    echo ""
    echo -e "  백업 상태 확인:"
    echo -e "    ${CYAN}oc get backup poc-oadp-backup -n ${NS}${NC}"
    echo ""
    echo -e "  복원 실행 (백업 완료 후):"
    echo -e "    ${CYAN}oc apply -f poc-oadp-restore.yaml${NC}"
    echo ""
    echo -e "  자세한 내용: 14-oadp/14-oadp.md"
    echo ""
}

# =============================================================================
# 정리
# =============================================================================
cleanup() {
    print_step "--cleanup: 14-oadp 리소스 삭제"
    local _oadp_ns="${OADP_NS:-openshift-adp}"
    oc delete project poc-oadp --ignore-not-found 2>/dev/null || true
    oc delete dataprotectionapplication poc-dpa -n "$_oadp_ns" --ignore-not-found 2>/dev/null || true
    oc delete secret cloud-credentials -n "$_oadp_ns" --ignore-not-found 2>/dev/null || true
    oc delete objectbucketclaim obc-backups -n "$_oadp_ns" --ignore-not-found 2>/dev/null || true
    oc delete volumesnapshotclass poc-volumesnapshotclass --ignore-not-found 2>/dev/null || true
    oc delete consoleyamlsample poc-dataprotectionapplication poc-backup poc-restore --ignore-not-found 2>/dev/null || true
    oc delete project poc-garage --ignore-not-found 2>/dev/null || true
    print_ok "14-oadp 리소스 성공적으로 삭제됨"
}

main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  OADP 실습 환경 구성${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    preflight
    step_namespace
    step_obc
    step_credentials
    step_volumesnapshotclass
    step_dpa
    step_verify
    step_vm_namespace
    step_vm
    step_backup
    step_consoleyamlsamples
    print_summary
}

[ "${1:-}" = "--cleanup" ] && { cleanup; exit 0; }
main
