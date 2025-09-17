# Quickstart: EKS + Argo CD (Learner Lab)

Siga este passo a passo simples para subir um cluster EKS por CloudFormation, instalar o Argo CD e fazer o primeiro deploy via GitOps. Focado em custo mínimo e baixo atrito no Learner Lab.

## Pré‑requisitos
- `awscli` v2, `kubectl`, `helm`
- Conta GitHub com este repositório e Docker Hub
- Perfil AWS configurado (ex.: `fiapaws`) com acesso nas regiões `us-east-1` ou `us-west-2`

## 1) Preparar variáveis (ENV)
Crie seu arquivo de variáveis a partir do exemplo e ajuste:

```bash
cp env/cfn.env.example env/cfn.fiapaws
```

Edite `env/cfn.fiapaws`:
```dotenv
AWS_REGION=us-east-1
AWS_PROFILE=fiapaws
CLUSTER_NAME=demo-12-factor-eks

# Em ambientes restritos do Lab, use LabRole para ambos (se disponível)
CLUSTER_ROLE_ARN=arn:aws:iam::<ACCOUNT_ID>:role/LabRole
NODE_ROLE_ARN=arn:aws:iam::<ACCOUNT_ID>:role/LabRole
```

## 2) Provisionar EKS + Argo CD (CloudFormation)
```bash
chmod +x scripts/deploy-cfn.sh scripts/destroy-cfn.sh
# (Opcional) Defina a senha do admin do Argo CD durante o deploy
# Exemplo: ARGOCD_ADMIN_PASSWORD='Fiap@2025!' 
ENV_FILE=env/cfn.fiapaws ARGOCD_ADMIN_PASSWORD='Fiap@2025!' scripts/deploy-cfn.sh
```
Verifique:
```bash
kubectl get nodes
kubectl -n argocd get pods
```

## 3) Ajustar a imagem do app
Edite `helm/demo-12-factor-app/values.yaml` e defina o repositório da sua imagem:
```yaml
image:
  repository: docker.io/<SEU_USUARIO>/demo-12-factor-app
```

Crie secrets no GitHub do repositório:
- `DOCKERHUB_USERNAME`
- `DOCKERHUB_TOKEN`

## 4) Criar a Application do Argo CD (passo manual)
Pela UI do Argo CD (ou via kubectl), aponte para este repo e o path do chart `helm/demo-12-factor-app`.

Exemplo de YAML mínimo (ajuste `repoURL`):
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: demo-12-factor-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/<SEU_USUARIO>/demo-12-factor-app.git
    targetRevision: main
    path: helm/demo-12-factor-app
    helm:
      releaseName: demo-12-factor-app
  destination:
    server: https://kubernetes.default.svc
    namespace: demo-12-factor-app
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```
Aplicar se usar arquivo:
```bash
kubectl apply -f argocd/your-app.yaml
kubectl -n argocd get applications
```

Login na UI do Argo CD (opcional):
```bash
# Encaminhar porta da UI
kubectl -n argocd port-forward svc/argocd-server 8080:80

# Usuário: admin
# Senha: se você definiu ARGOCD_ADMIN_PASSWORD, use-a (ex.: Fiap@2025!)
# Caso contrário, senha inicial:
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

## 5) Pipeline (primeiro deploy)
Faça um commit na branch `main`. O workflow:
1. Builda e publica a imagem no Docker Hub
2. Atualiza `image.tag` em `values.yaml` para `sha-<commit>`
3. Argo CD sincroniza o cluster

## 6) Acessar a aplicação
O Service é `type: LoadBalancer` com NLB. Aguarde o hostname:
```bash
kubectl -n demo-12-factor-app get svc
curl http://<EXTERNAL-HOSTNAME>/healthz
```

## 7) Encerrar recursos (economia de orçamento)
```bash
ENV_FILE=env/cfn.fiapaws scripts/destroy-cfn.sh
```

## Observações
- Sem banco de dados por padrão; app está stateless.
- Sem Ingress/ALB neste momento; quando quiser evoluir para ALB (camada 7), instale o AWS Load Balancer Controller e adicione um Ingress.
