// Jenkinsfile - FreeRDP-WebConnect (scripted pipeline)
//
// Pipeline:
//   1. Checkout
//   2. Build   - cmake + make to compile wsgate
//   3. Docker  - build + push wsgate image to Docker Hub on the dedicated
//                `freerdp-build` agent (inherits from base, has FreeRDP 1.1 + EHS).
//   4. Render  - Kubernetes manifest with the concrete image tag,
//                archived as a build artifact.
//   5. Deploy  - `kubectl apply` to the cluster, gated: only when the change
//                is on branch 'main' OR the commit message contains '{DEPLOY}'.
//                Verified via `kubectl rollout status` (fails on timeout).
//
// Requirements:
//   - The `freerdp-build` agent label is defined in the greenfield JCasC
//     Kubernetes cloud templates (values.yaml -> agent image:
//     antanoio/jenkins-agent-freerdp:1.0.0).
//   - `docker` CLI is available in the freerdp-build agent container.
//   - `kubectl` on PATH + network access to the cluster API (for the Deploy stage).
//   - A Jenkins *file* credential ID `freerdp-kubeconfig` holding a kubeconfig
//     for a user with RBAC in namespace `freerdp-webconnect`.

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------
def REGISTRY        = 'https://index.docker.io/v1/'
def IMAGE_NAME      = 'antanoio/wsgate'
def BRANCH_TAG      = (env.BRANCH_NAME ?: 'main').toLowerCase().replaceAll(/[^a-z0-9._-]/, '-')
def IMAGE_TAG       = (BRANCH_TAG == 'main') ? "${env.BUILD_NUMBER}" : "${BRANCH_TAG}-${env.BUILD_NUMBER}"
def FULL_IMAGE      = "${IMAGE_NAME}:${IMAGE_TAG}"
def DOCKERHUB_CREDS = 'dockerhub-credentials'

def K8S_MANIFEST    = 'kubernetes/deployment.yaml'
def KUBECONFIG_ID   = 'freerdp-kubeconfig'
def DEPLOY_NS       = 'freerdp-webconnect'
def DEPLOY_NAME     = 'wsgate'

properties([
    parameters([
        booleanParam(name: 'DEPLOY', defaultValue: false,
                     description: 'Force the Kubernetes deploy ({DEPLOY} gate)'),
    ])
])

def shouldDeploy = {
    (env.BRANCH_NAME == 'main') || params.DEPLOY || it.contains('{DEPLOY}')
}

// ---------------------------------------------------------------------------
// Pipeline
// ---------------------------------------------------------------------------
node('freerdp-build') {
    try {
        stage('Checkout') {
            checkout scm
            def deployMsg = sh(script: 'git log -1 --pretty=%s', returnStdout: true).trim()
            currentBuild.description = "commit: ${deployMsg}"
        }

        stage('Build') {
            sh 'mkdir -p build'
            dir('build') {
                sh 'cmake ..'
                sh 'make -j$(nproc)'
            }
            archiveArtifacts artifacts: 'build/wsgate', fingerprint: true
        }

        stage('Docker · Build & Push') {
            stash name: 'docker-context',
                  includes: 'Dockerfile,build/wsgate,webroot/**,kubernetes/**',
                  allowEmpty: false

            // Re-use the same freerdp-build agent for Docker; its image does
            // not contain a Docker daemon, so we rely on the host Docker socket
            // or a sidecar. If your freerdp-build template adds a dind sidecar,
            // configure DOCKER_HOST accordingly.
            def image = docker.build("${FULL_IMAGE}", '-f Dockerfile .')
            docker.withRegistry(REGISTRY, DOCKERHUB_CREDS) {
                image.push()
                image.push('latest')
            }
        }

        stage('Kubernetes · Render Manifest') {
            sh "sed -i 's|__IMAGE__|${FULL_IMAGE}|g' ${K8S_MANIFEST}"
            archiveArtifacts artifacts: K8S_MANIFEST,
                              fingerprint: true,
                              onlyIfSuccessful: true
        }

        stage('Kubernetes · Deploy') {
            def deployMsg = sh(script: 'git log -1 --pretty=%s', returnStdout: true).trim()
            def branch    = env.BRANCH_NAME ?: sh(script: 'git rev-parse --abbrev-ref HEAD', returnStdout: true).trim()
            if (!shouldDeploy(deployMsg)) {
                echo "Skipping deploy: branch='${branch}', commit='${deployMsg}' " +
                     "(not on 'main' and no '{DEPLOY}' marker)."
                return
            }
            echo "Deploying ${FULL_IMAGE} to namespace '${DEPLOY_NS}' (branch='${branch}')."
            withCredentials([file(credentialsId: KUBECONFIG_ID, variable: 'KUBECONFIG')]) {
                sh """
                    kubectl apply -f ${K8S_MANIFEST}
                    kubectl -n ${DEPLOY_NS} rollout status deploy/${DEPLOY_NAME} --timeout=180s
                """
            }
        }
    } finally {
        stage('Report') {
            try {
                junit testResults: '**/build/test-results/**/*.xml', allowEmptyResults: true
            } catch (Exception e) {
                echo "No JUnit test results found: ${e.message}"
            }
        }

        stage('Slack Notify') {
            def color_good = '#00FF00'
            def color_unstable = '#eb9b34'
            def color_error = '#EE0000FF'
            if (currentBuild.currentResult == 'FAILURE') {
                slackSend(color: "${color_error}", message: "*${currentBuild.currentResult}:* Job '${env.JOB_NAME} [${env.BUILD_NUMBER}]' (${env.BUILD_URL})\nImage: ${FULL_IMAGE}")
            }
            if (currentBuild.currentResult == 'UNSTABLE') {
                slackSend(color: "${color_unstable}", message: "*${currentBuild.currentResult}:* Job '${env.JOB_NAME} [${env.BUILD_NUMBER}]' (${env.BUILD_URL})\nImage: ${FULL_IMAGE}")
            }
            if (currentBuild.currentResult == 'SUCCESS') {
                slackSend(color: "${color_good}", message: "*${currentBuild.currentResult}:* Job '${env.JOB_NAME} [${env.BUILD_NUMBER}]' (${env.BUILD_URL})\nImage: ${FULL_IMAGE}")
            }
        }

        cleanWs()
    }
}
