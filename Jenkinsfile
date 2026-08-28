// Jenkinsfile - FreeRDP-WebConnect (scripted pipeline)
//
// Pipeline:
//   1. Checkout
//   2. Build   - cmake + make to compile wsgate (source lives in wsgate/)
//   3. Docker  - build + push wsgate image on the `container-build` agent
//                (DinD sidecar, no host Docker socket).
//   4. Render  - Kubernetes manifest with the concrete image tag,
//                archived as a build artifact.
//   5. Deploy  - `kubectl apply` to the cluster, gated: only when the change
//                is on branch 'main' OR the commit message contains '{DEPLOY}'.
//                Verified via `kubectl rollout status` (fails on timeout).
//
// Requirements:
//   - `freerdp-build` agent: has FreeRDP 1.1 + EHS + C++ toolchain (agent image
//     antanoio/jenkins-agent-freerdp:1.0.0).
//   - `container-build` agent: Docker CLI + DinD sidecar (DOCKER_HOST set).
//   - `kubectl` on PATH + network access to the cluster API (for the Deploy stage).
//   - A Jenkins *file* credential ID `calistix-kubeconfig` holding a kubeconfig
//     with cluster deploy permissions (same one used by calistix_web).

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
def KUBECONFIG_ID   = 'calistix-kubeconfig'
def DEPLOY_NS       = 'freerdp-webconnect'
def DEPLOY_NAME     = 'wsgate'

// wsgate's CMakeLists.txt lives in the wsgate/ subdirectory. GCC 14 turns
// implicit declarations into errors, so the same relax flags as the agent
// image build are used here.
def CMAKE_FLAGS = [
    '-DHAVE_CPLUSPLUS11=ON',
    '-DCMAKE_C_FLAGS="-Wno-implicit-function-declaration -Wno-int-conversion -Wno-incompatible-pointer-types"',
    '-DCMAKE_CXX_FLAGS="-std=c++11 -Wno-implicit-function-declaration -Wno-int-conversion -Wno-incompatible-pointer-types"'
].join(' ')

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
def buildResult = 'SUCCESS'

node('freerdp-build') {
    try {
        stage('Checkout') {
            checkout scm
            def deployMsg = sh(script: 'git log -1 --pretty=%s', returnStdout: true).trim()
            currentBuild.description = "commit: ${deployMsg}"
        }

        stage('Build') {
            dir('wsgate') {
                sh 'rm -rf build && mkdir -p build'
                dir('build') {
                    sh "cmake ${CMAKE_FLAGS} .."
                    sh 'make -j$(nproc)'
                }
            }
            archiveArtifacts artifacts: 'wsgate/build/wsgate', fingerprint: true
        }

        stage('Docker · Build & Push') {
            // The Dockerfile builds wsgate from the wsgate/ source tree, so the
            // whole context must be stashed for the container-build agent.
            stash name: 'docker-context',
                  includes: 'Dockerfile,.dockerignore,wsgate/**,kubernetes/**',
                  allowEmpty: false

            node('container-build') {
                unstash 'docker-context'
                def image = docker.build("${FULL_IMAGE}", '-f Dockerfile .')
                docker.withRegistry(REGISTRY, DOCKERHUB_CREDS) {
                    image.push()
                    image.push('latest')
                }
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
                    # Deploy the wsgate runtime config as a Secret (source of truth is
                    # kubernetes/wsgate.ini in this repo).
                    kubectl create secret generic wsgate-config \\
                        --from-file=wsgate.ini=kubernetes/wsgate.ini \\
                        --dry-run=client -o yaml | kubectl apply -n ${DEPLOY_NS} -f -
                    kubectl apply -f ${K8S_MANIFEST}
                    kubectl -n ${DEPLOY_NS} rollout status deploy/${DEPLOY_NAME} --timeout=180s
                """
            }
        }
    } catch (Exception e) {
        buildResult = 'FAILURE'
        echo "Pipeline failed: ${e}"
        throw e
    } finally {
        stage('Report') {
            try {
                junit testResults: '**/build/test-results/**/*.xml', allowEmptyResults: true
            } catch (Exception e) {
                echo "No JUnit test results found: ${e.message}"
            }
        }

        stage('Slack Notify') {
            // In scripted pipelines currentBuild.currentResult is not updated yet
            // inside the finally block, so use the flag captured in the catch.
            def outcome = (buildResult == 'SUCCESS') ? currentBuild.currentResult : buildResult
            def color = '#00FF00'
            if (outcome == 'FAILURE')      { color = '#EE0000FF' }
            else if (outcome == 'UNSTABLE') { color = '#eb9b34' }
            else if (outcome == 'ABORTED')  { color = '#FF8C00' }
            slackSend(color: color,
                      message: "*${outcome}:* Job '${env.JOB_NAME} [${env.BUILD_NUMBER}]' (${env.BUILD_URL})\nImage: ${FULL_IMAGE}")
        }

        cleanWs()
    }
}
