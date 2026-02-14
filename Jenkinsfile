pipeline {
    agent any

    environment {
        AWS_REGION = credentials('aws-region')
        ECR_URI    = credentials('ecr-uri')
        GIT_REPO   = credentials('git-repo-url')

        IMAGE_TAG = "v${BUILD_NUMBER}"
        FULL_IMAGE_NAME = "${ECR_URI}:${IMAGE_TAG}"
    }

    stages {
        stage('Checkout Source Code') {
            steps {
                git url: "${GIT_REPO}", branch: 'main'
            }
        }

        stage('Docker Build') {
            steps {
                sh """
                  echo "Building Docker image: ${FULL_IMAGE_NAME}"
                  docker build -t brain-tasks-app:${IMAGE_TAG} .
                """
            }
        }

        stage('Login to AWS ECR') {
            steps {
                withCredentials([[
                    $class: 'AmazonWebServicesCredentialsBinding',
                    credentialsId: 'aws-creds',
                    accessKeyVariable: 'AWS_ACCESS_KEY_ID',
                    secretKeyVariable: 'AWS_SECRET_ACCESS_KEY'
                ]]) {
                    sh """
                      aws ecr get-login-password --region ${AWS_REGION} |
                      docker login --username AWS --password-stdin ${ECR_URI}
                    """
                }
            }
        }

        stage('Tag & Push Image to ECR') {
            steps {
                sh """
                  docker tag brain-tasks-app:${IMAGE_TAG} ${FULL_IMAGE_NAME}
                  docker push ${FULL_IMAGE_NAME}
                """
            }
        }

        stage('Configure EKS Cluster') {
            steps {
                sh """
                  aws eks update-kubeconfig \
                    --region ${AWS_REGION} \
                    --name brain-tasks-eks
                """
            }
        }

        stage('Deploy to EKS') {
            steps {
                sh """
                echo "Deploying image ${FULL_IMAGE_NAME} to cluster brain-tasks-eks"
                kubectl set image deployment/brain-tasks-app \
                brain-tasks=${FULL_IMAGE_NAME} || true
                pwd
                ls -la
                ls -la k8s/app
                kubectl apply -f k8s/app/
                """
            }
        }

        stage('Show Application URL') {
            steps {
                sh """
                  echo "Waiting for LoadBalancer external IP..."

                  for i in {1..20}; do
                    EXTERNAL_IP=\$(kubectl get svc brain-tasks-service \
                      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

                    if [ -n "\$EXTERNAL_IP" ]; then
                      echo "=============================================="
                      echo "✅ Application is LIVE"
                      echo "🌍 URL: http://\$EXTERNAL_IP:3000"
                      echo "=============================================="
                      exit 0
                    fi

                    echo "Still waiting for external IP..."
                    sleep 15
                  done

                  echo "❌ LoadBalancer external IP not assigned yet"
                  exit 1
                """
            }
        }
    }

    post {
        success {
            echo "✅ Deployment successful: ${FULL_IMAGE_NAME}"
        }
        failure {
            echo '❌ Deployment failed'
        }
    }
}
